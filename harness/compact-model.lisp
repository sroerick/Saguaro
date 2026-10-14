;;; compact-model.lisp — run conversation COMPACTION under a borrowed model.
;;;
;;; Compaction always runs under *compaction-borrowed-model*, and the session's
;;; own (pinned) provider is ALWAYS restored afterwards via UNWIND-PROTECT.
;;; Configuration and preferences are never touched, so the pinned model cannot
;;; drift to the borrowed one.
;;;
;;; History:
;;;   2026-10-11 — built: unconditional borrow for every compaction.
;;;   2026-10-12 — briefly changed to FALLBACK-only (try the pinned model first)
;;;     while the box was on OpenCode Go.
;;;   2026-10-14 — reverted to UNCONDITIONAL. The box moved to the **Synthetic**
;;;     provider, and Synthetic chokes on the compaction request (a full-context
;;;     summarization) regardless of which model is pinned, so trying the pinned
;;;     model first just burns a long failing attempt before the borrow. Also on
;;;     2026-10-14 the borrowed model was repointed from `opencode/kimi-k3`
;;;     (OpenCode Go, now answering HTTP 429 GoUsageLimitError, weekly quota) to
;;;     `hf:moonshotai/Kimi-K3`, which is served by the SAME (Synthetic) provider
;;;     so compaction does not depend on a second provider's quota. Verified
;;;     directly: hf:moonshotai/Kimi-K3 summarizes a 287K-token prompt in ~29s.
;;;
;;; SCOPE: this wraps COMPACTION only. A pinned-model failure during a normal
;;; turn (Synthetic's ~180s HTTP 408 on very large contexts) is not covered here.
;;;
;;; Toggle off: set *compaction-borrow-p* NIL before this loads, or drop the
;;; (load ...) line from ~/.config/autolith/init.lisp.
;;;
;;; Pinned to autolith 0.62.1 internals: agent-compact-conversation,
;;; agent-provider, agent-configuration, provider-create, configuration-copy
;;; (:model). Re-check these on every autolith upgrade.

(in-package :autolith)

(defparameter *compaction-borrow-p* t
  "When true, compaction always runs under *compaction-borrowed-model*.")

;; Back-compat aliases for the 2026-10-11/12 names.
(defparameter *compaction-use-fallback* *compaction-borrow-p*
  "Deprecated alias of *compaction-borrow-p*.")
(defparameter *compaction-use-kimi* *compaction-borrow-p*
  "Deprecated alias of *compaction-borrow-p*.")

(defparameter *compaction-borrowed-model* "hf:moonshotai/Kimi-K3"
  "Model used for compaction summarization (never pinned).")

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
  (when (and *compaction-borrow-p* (not *compact-model-wrapped-p*))
    (let ((original (fdefinition 'agent-compact-conversation)))
      (setf (fdefinition 'agent-compact-conversation)
            (lambda (agent observer &rest args)
              (let ((saved (agent-provider agent)))
                (unwind-protect
                     (progn
                       (%compact-model-borrow agent)
                       (%compact-model-note "compaction: borrowing ~A"
                                            *compaction-borrowed-model*)
                       (apply original agent observer args))
                  (setf (agent-provider agent) saved)
                  (%compact-model-note "compaction: restored original provider")))))
      (setf *compact-model-wrapped-p* t)
      (%compact-model-note
       "compact-model installed: BORROW-ALWAYS mode (compaction under ~A, pinned model restored after)"
       *compaction-borrowed-model*))))

(%compact-model-install)
