;;; compact-model.lisp — run conversation COMPACTION through a MODEL LADDER.
;;;
;;; 2026-10-15: LADDER (owner's design).
;;;   Rung 1 = the session's PINNED model (cheap: GLM-5.3-Flash is far cheaper
;;;            than K3, and it does handle compaction-sized prompts on Synthetic
;;;            — measured 2026-10-15: a 362K-token compaction-shaped prompt got
;;;            HTTP 200 in 27.5s).
;;;   Rung 2 = the BORROWED model (*compaction-borrowed-model*).
;;; Each rung is tried *compaction-attempts-per-rung* times; EVERY attempt is
;;; logged to the beacon, so a failure stops being invisible. If every rung
;;; fails, the last condition propagates UNCHANGED — the turn still aborts and
;;; the no-text guard still pages. That behaviour is not changed here.
;;;
;;; WHY (2026-10-15 14:38 outage): the revision before this one borrowed K3
;;; UNCONDITIONALLY and had NO handler, so one TRANSIENT 408 on the borrowed
;;; compaction killed the whole turn -> "(no text output)". Compaction at this
;;; size is routine (this conversation has 8 successful compactions at 391-399K
;;; input tokens, one of them under the pinned model's era) — it is NOT a size
;;; ceiling, and AUTOLITH_COMPACTION_THRESHOLD should NOT be lowered.
;;;
;;; COST: K3 tokens are paid only when the pinned model fails. The 10-14
;;; unconditional-borrow revision paid K3 on every compaction.
;;; History: 10-11 built (unconditional borrow) | 10-12 FALLBACK-only (OpenCode
;;; Go) | 10-14 back to unconditional (Synthetic era; the handler caught the
;;; wrong condition and missed the 408) | 10-15 LADDER + per-rung retries +
;;; full attempt logging.
;;;
;;; Toggle off: set *compaction-ladder-enabled* to NIL before this loads, or
;;; drop the (load ...) line from ~/.config/autolith/init.lisp.
;;;
;;; Pinned to autolith 0.62.1 internals: agent-compact-conversation,
;;; agent-provider, agent-configuration, provider-create, configuration-copy
;;; (:model), provider-error / provider-error-status (cl-llm-provider-api,
;;; re-exported by autolith). Re-check these on every autolith upgrade.

(in-package :autolith)

(defparameter *compaction-ladder-enabled* t
  "When true, compaction runs through *compaction-ladder* with per-rung retries.")

;; Back-compat aliases for the 2026-10-11/12/14 names.
(defparameter *compaction-borrow-p* *compaction-ladder-enabled*)
(defparameter *compaction-use-fallback* *compaction-ladder-enabled*)
(defparameter *compaction-use-kimi* *compaction-ladder-enabled*)

(defparameter *compaction-borrowed-model* "hf:moonshotai/Kimi-K3"
  "Escalation model. Used only after the pinned model has failed (never pinned).")

(defparameter *compaction-ladder* (list nil *compaction-borrowed-model*)
  "Compaction attempts, in ORDER. NIL means the session's pinned provider.")

(defparameter *compaction-attempts-per-rung* 2
  "Times each rung of *compaction-ladder* is tried before escalating.")

(defparameter *compact-model-beacon*
  (merge-pathnames ".cache/compact-model-swap.log" (user-homedir-pathname))
  "Append-only record of every compaction attempt and provider swap.")

(defvar *compact-model-original* nil
  "The pristine AGENT-COMPACT-CONVERSATION captured at install time. DEFVAR so
a reload in the same image re-installs without stacking wrappers.")

(defvar *compact-model-wrapped-p* nil
  "Guard so reloading this file does not stack wrappers.")

(defun %compact-model-note (fmt &rest args)
  "Best-effort append to the swap beacon; never signals."
  (ignore-errors
    (with-open-file (s *compact-model-beacon*
                       :direction :output
                       :if-exists :append
                       :if-does-not-exist :create)
      (format s "~&~A ~A~%" (get-universal-time)
              (apply #'format nil fmt args)))))

(defun %compact-model-label (model)
  (or model "pinned model"))

(defun %compact-model-set-provider (agent saved model)
  "Point AGENT's runtime provider at MODEL (NIL = the pinned provider SAVED).
Runtime-only: configuration and preferences are never touched."
  (setf (agent-provider agent)
        (if (null model)
            saved
            (provider-create
             (configuration-copy (agent-configuration agent) :model model)))))

(defun %compact-model-run (agent observer args)
  "Try the compaction under each ladder rung, retrying each rung in place.
Signals the LAST provider-error if every rung fails."
  (let ((saved (agent-provider agent))
        (original *compact-model-original*)
        (per-rung *compaction-attempts-per-rung*)
        (last-condition nil))
    (unless original
      (%compact-model-note "compact-model: no saved original; running unwrapped")
      (return-from %compact-model-run (apply (fdefinition 'agent-compact-conversation)
                                             agent observer args)))
    (unwind-protect
         (dolist (model *compaction-ladder*)
           (%compact-model-set-provider agent saved model)
           (dotimes (attempt per-rung)
             (handler-case
                 (let ((result (apply original agent observer args)))
                   (%compact-model-note "compaction OK under ~A (attempt ~D/~D)"
                                        (%compact-model-label model)
                                        (1+ attempt) per-rung)
                   (return-from %compact-model-run result))
               (provider-error (cause)
                 (setf last-condition cause)
                 (%compact-model-note
                  "compaction FAILED under ~A (attempt ~D/~D): ~A status ~A"
                  (%compact-model-label model) (1+ attempt) per-rung
                  (type-of cause) (ignore-errors (provider-error-status cause)))))))
      (setf (agent-provider agent) saved)
      (%compact-model-note "compaction: restored original provider"))
    (%compact-model-note "compaction: EVERY rung failed (~A entries); giving up"
                         (length *compaction-ladder*))
    (error last-condition)))

(defun %compact-model-install ()
  (when *compaction-ladder-enabled*
    (unless *compaction-ladder*
      (%compact-model-note "compact-model: empty ladder; forcing pinned-only")
      (setf *compaction-ladder* (list nil)))
    (when (null *compact-model-original*)
      (setf *compact-model-original* (fdefinition 'agent-compact-conversation)))
    (setf (fdefinition 'agent-compact-conversation)
          (lambda (agent observer &rest args)
            (%compact-model-run agent observer args)))
    (setf *compact-model-wrapped-p* t)
    (%compact-model-note
     "compact-model installed: LADDER ~{~A~^ -> ~} (x~D attempts per rung)"
     (mapcar #'%compact-model-label *compaction-ladder*)
     *compaction-attempts-per-rung*)))

(%compact-model-install)
