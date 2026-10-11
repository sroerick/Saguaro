;;; compact-model.lisp — run Autolith conversation compaction under a BORROWED
;;; model (kimi-k3), then restore the session's own provider/model.
;;;
;;; Why: on this provider, glm-5.3-flash cannot summarize a large standing
;;; conversation ("Compaction produced no summary text."), which aborts the
;;; turn. kimi-k3 can. We want kimi ONLY for compaction, never as the pinned
;;; model. A failed restore is expensive, so the swap is done on the agent's
;;; runtime provider slot and ALWAYS undone via UNWIND-PROTECT. The
;;; configuration/preferences are never touched, so nothing can drift to kimi.
;;;
;;; Toggle off (e.g. after an upstream compaction fix): set
;;;   *compaction-use-kimi* NIL before this file loads, or drop its (load ...)
;;;   line from ~/.config/autolith/init.lisp.
;;;
;;; Pinned to autolith 0.62.1 internals:
;;;   agent-compact-conversation, agent-provider, agent-configuration,
;;;   provider-create, configuration-copy (:model).
;;; Re-check these on every autolith upgrade.

(in-package :autolith)

(defparameter *compaction-use-kimi* t
  "When true, conversation compaction runs under *compaction-borrowed-model*.")

(defparameter *compaction-borrowed-model* "opencode/kimi-k3"
  "Model used only for compaction summarization (never pinned).")

(defparameter *compact-model-beacon*
  (merge-pathnames ".cache/compact-model-swap.log" (user-homedir-pathname))
  "Append-only record of every compaction provider swap.")

(defvar *compact-model-wrapped-p* nil
  "Guard so reloading this file does not stack wrappers. DEFVAR (not
DEFPARAMETER) so a replay/reload in the same image keeps it true.")

(defun %compact-model-note (fmt &rest args)
  "Best-effort append to the swap beacon; never signals."
  (ignore-errors
    (with-open-file (s *compact-model-beacon*
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create)
      (format s "~&~A ~A~%" (get-universal-time)
              (apply #'format nil fmt args)))))

(defun %compact-model-install ()
  (when (and *compaction-use-kimi* (not *compact-model-wrapped-p*))
    (let ((original (fdefinition 'agent-compact-conversation)))
      (setf (fdefinition 'agent-compact-conversation)
            (lambda (agent observer &rest args)
              (let ((saved (agent-provider agent)))
                (unwind-protect
                     (progn
                       (setf (agent-provider agent)
                             (provider-create
                              (configuration-copy (agent-configuration agent)
                                                  :model *compaction-borrowed-model*)))
                       (%compact-model-note "compaction: borrowing ~A"
                                            *compaction-borrowed-model*)
                       (apply original agent observer args))
                  (setf (agent-provider agent) saved)
                  (%compact-model-note "compaction: restored original provider")))))
      (setf *compact-model-wrapped-p* t)
      (%compact-model-note "compact-model installed: borrow ~A"
                           *compaction-borrowed-model*))))

(%compact-model-install)
