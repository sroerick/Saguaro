;;; compact-model.lisp — FALLBACK compaction model.
;;;
;;; Run Autolith conversation compaction under the PINNED model, and borrow a
;;; different model ONLY if that compaction raises a provider error.
;;;
;;; History:
;;;   2026-10-11 — this file UNCONDITIONALLY borrowed a model for every
;;;     compaction, to work around "Compaction produced no summary text." on
;;;     opencode/glm-5.3-flash at large context. It worked, but paid for the
;;;     borrowed model on ~every compaction (~1 per 2h; 21 borrows in 41h).
;;;   2026-10-12 — converted to FALLBACK: try the pinned model first; only on a
;;;     compaction failure retry ONCE under *compaction-borrowed-model*.
;;;   2026-10-14 — this box moved from OpenCode Go to **Synthetic**
;;;     (pin = hf:zai-org/GLM-5.3-Flash). Two repairs:
;;;       (a) the borrowed model was still `opencode/kimi-k3`, and OpenCode Go
;;;           now answers HTTP 429 GoUsageLimitError ("Go usage limit exceeded",
;;;           weekly) — i.e. the fallback was DEAD. Repointed to
;;;           `hf:moonshotai/Kimi-K3`, which is on the SAME (Synthetic) provider
;;;           so the fallback never depends on a second provider's quota.
;;;           Verified: hf:moonshotai/Kimi-K3 summarizes a 287K-token prompt in
;;;           ~29s (HTTP 200, visible text).
;;;       (b) the handler caught only PROVIDER-PROTOCOL-ERROR, but Synthetic
;;;           fails large requests with HTTP 408, which autolith signals as a
;;;           plain PROVIDER-ERROR (`:RETRYABLE-P NIL`; 408 is not in
;;;           *provider-retryable-http-statuses* = (500 502 503 504 507)).
;;;           So the fallback never fired on the failure we actually get.
;;;           Now catches PROVIDER-ERROR — the common parent of protocol,
;;;           retryable, plain and unauthorized provider failures.
;;;
;;; Both providers are swapped on the agent's runtime provider slot and ALWAYS
;;; restored (UNWIND-PROTECT); configuration and preferences are never touched,
;;; so the pinned model cannot drift to the borrowed model.
;;;
;;; SCOPE LIMIT: this only wraps a COMPACTION. A pinned-model failure during a
;;; normal turn (the Synthetic ~180s HTTP 408 on very large contexts) is not
;;; covered here and still aborts the turn.
;;;
;;; Toggle off: set *compaction-use-fallback* NIL before this loads, or drop the
;;; (load ...) line from ~/.config/autolith/init.lisp.
;;;
;;; Pinned to autolith 0.62.1 internals: agent-compact-conversation,
;;; agent-provider, agent-configuration, provider-create, configuration-copy
;;; (:model), provider-error (cl-llm-provider-api, re-exported by autolith).
;;; Re-check these on every autolith upgrade.

(in-package :autolith)

(defparameter *compaction-use-fallback* t
  "When true, a failed compaction is retried under *compaction-borrowed-model*.")

;; Kept for backward compatibility with the 2026-10-11/12 name.
(defparameter *compaction-use-kimi* *compaction-use-fallback*
  "Deprecated alias of *compaction-use-fallback*.")

(defparameter *compaction-borrowed-model* "hf:moonshotai/Kimi-K3"
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
  (when (and *compaction-use-fallback* (not *compact-model-wrapped-p*))
    (let ((original (fdefinition 'agent-compact-conversation)))
      (setf (fdefinition 'agent-compact-conversation)
            (lambda (agent observer &rest args)
              (let ((saved (agent-provider agent)))
                (unwind-protect
                     (handler-case
                         ;; First attempt: whatever model is pinned right now.
                         (apply original agent observer args)
                       (provider-error (cause)
                         ;; Compaction failed under the pinned model — either
                         ;; "Compaction produced no summary text."
                         ;; (provider-protocol-error) or an HTTP status failure
                         ;; such as the Synthetic 408 (plain provider-error).
                         ;; Retry ONCE under the borrowed model; if that fails
                         ;; too, its condition propagates unchanged.
                         (%compact-model-note
                          "compaction failed under pinned model (~A status ~A); borrowing ~A"
                          (type-of cause)
                          (ignore-errors (provider-error-status cause))
                          *compaction-borrowed-model*)
                         (%compact-model-borrow agent)
                         (apply original agent observer args)))
                  (setf (agent-provider agent) saved)))))
      (setf *compact-model-wrapped-p* t)
      (%compact-model-note
       "compact-model installed: FALLBACK mode (borrow ~A only on compaction failure)"
       *compaction-borrowed-model*))))

(%compact-model-install)
