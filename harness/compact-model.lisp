;;; compact-model.lisp — FALLBACK compaction model.
;;;
;;; Run Autolith conversation compaction under the PINNED model, and borrow a
;;; different model ONLY if that compaction raises PROVIDER-PROTOCOL-ERROR.
;;;
;;; History:
;;;   2026-10-11 — this file UNCONDITIONALLY borrowed opencode/kimi-k3 for every
;;;     compaction, to work around "Compaction produced no summary text." on
;;;     opencode/glm-5.3-flash at large (~160K+) context. It worked, but paid
;;;     kimi tokens on ~every compaction (~1 per 2h; 21 borrows in 41h).
;;;   2026-10-12 — gregor was moved to the regular (non-flash) opencode/glm-5.3,
;;;     which summarizes large contexts fine. The borrow is now a FALLBACK:
;;;     try the pinned model first; only on a compaction failure retry ONCE
;;;     under *compaction-borrowed-model*.
;;;
;;; Both providers are swapped on the agent's runtime provider slot and ALWAYS
;;; restored (UNWIND-PROTECT); configuration and preferences are never touched,
;;; so the pinned model cannot drift to the borrowed model.
;;;
;;; Toggle off: set *compaction-use-kimi* NIL before this loads, or drop the
;;; (load ...) line from ~/.config/autolith/init.lisp.
;;;
;;; Pinned to autolith 0.62.1 internals: agent-compact-conversation,
;;; agent-provider, agent-configuration, provider-create, configuration-copy
;;; (:model), provider-protocol-error (cl-llm-provider-api, re-exported by
;;; autolith). Re-check these on every autolith upgrade.

(in-package :autolith)

(defparameter *compaction-use-kimi* t
  "When true, a failed compaction is retried under *compaction-borrowed-model*.")

(defparameter *compaction-borrowed-model* "opencode/kimi-k3"
  "Model used only to RETRY a failed compaction (never pinned).")

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

(defun %compact-model-borrow (agent)
  "Point AGENT's runtime provider at the borrowed compaction model."
  (setf (agent-provider agent)
        (provider-create
         (configuration-copy (agent-configuration agent)
                             :model *compaction-borrowed-model*))))

(defun %compact-model-install ()
  (when (and *compaction-use-kimi* (not *compact-model-wrapped-p*))
    (let ((original (fdefinition 'agent-compact-conversation)))
      (setf (fdefinition 'agent-compact-conversation)
            (lambda (agent observer &rest args)
              (let ((saved (agent-provider agent)))
                (unwind-protect
                     (handler-case
                         ;; First attempt: whatever model is pinned right now.
                         (apply original agent observer args)
                       (provider-protocol-error (cause)
                         ;; Compaction failed under the pinned model (typically
                         ;; "Compaction produced no summary text."). Retry ONCE
                         ;; under the borrowed model; if that fails too, its
                         ;; condition propagates unchanged.
                         (%compact-model-note
                          "compaction failed under pinned model (~A); borrowing ~A"
                          (type-of cause) *compaction-borrowed-model*)
                         (%compact-model-borrow agent)
                         (apply original agent observer args)))
                  (setf (agent-provider agent) saved)))))
      (setf *compact-model-wrapped-p* t)
      (%compact-model-note
       "compact-model installed: FALLBACK mode (borrow ~A only on compaction failure)"
       *compaction-borrowed-model*))))

(%compact-model-install)
