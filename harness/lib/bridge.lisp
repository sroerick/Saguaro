;;;; bridge.lisp -- the runnable bridge: config-driven start-up of each

;;;; adapter, the main loop that paces their pollers, the unattended picker
;;;; watcher, and the process-level failure exit.
;;;; 
;;;; This is the only module that knows which adapters exist; harness/bridge.lisp
;;;; loads the modules in order and calls MAIN.

(defpackage :SG.BRIDGE
  (:use :CL :SG.CORE :SG.AUTOLITH :SG.XMPP :SG.PP :SG.TUNA :SG.ZULIP)
  (:export
   #:*PICKER-LAST*
   #:*PICKER-PANE*
   #:*PICKER-MARKER*
   #:*BLOCKER-MARKER*
   #:PICKER-WATCH
   #:*MAIN-LAST-KEEPALIVE*
   #:*MAIN-LAST-PP-POLL*
   #:*MAIN-LAST-TUNA-POLL*
   #:*MAIN-LAST-FLUSH*
   #:*MAIN-LAST-TASK-POLL*
   #:*MAIN-LAST-XMPP-PING*
   #:*MAIN-NEXT-XMPP-TRY*
   #:*LAST-INBOUND*
   #:MAIN
   #:XMPP-NEXT-STANZA-WITH-TIMEOUT
   #:FATAL-EXIT))
(in-package :SG.BRIDGE)

;;; ---------------------------------------------------------------------
;;; picker watcher (unattended TUI: answer blocking pickers/debuggers)
;;; ---------------------------------------------------------------------

(defparameter *picker-last* 0)
(defparameter *picker-pane* (cfg-str "bridge" "pane" "alagent"))
(defparameter *picker-marker* "do not run the command")
(defparameter *blocker-marker* "enter selects, esc cancels")

(defun picker-watch ()
  (when (> (- (now) *picker-last*) 45)
    (setf *picker-last* (now))
    (multiple-value-bind (cap err code)
        (run-capture (list "/usr/bin/tmux" "capture-pane"
                           "-t" *picker-pane* "-p") 15)
      (declare (ignore err))
      (when (zerop code)
        (when (or (search *picker-marker* cap :test #'char-equal)
                  (search *blocker-marker* cap :test #'char-equal))
          (run-capture (list "/usr/bin/tmux" "send-keys" "-t" *picker-pane*
                             "Enter") 15)
          (log-line "auto-answered blocking picker/debugger"))))))

;;; ---------------------------------------------------------------------
;;; main loop
;;; ---------------------------------------------------------------------

(defparameter *main-last-keepalive* 0)
(defparameter *main-last-pp-poll* 0)
(defparameter *main-last-tuna-poll* 0)
(defparameter *main-last-flush* 0)
(defparameter *main-last-task-poll* 0)
(defparameter *main-last-xmpp-ping* 0)
;; When xmpp is enabled but the stream is down while pp keeps serving, the
;; outer loop is already inside the serve pass, so the connect block will not
;; be revisited on its own. This timestamp gates the re-attempt.
(defparameter *main-next-xmpp-try* 0)

(defun main ()
  (load-state)
  (when *xmpp-on*
    ;; kill parentless s_client transports from a previous crash/bounce
    ;; BEFORE we spawn our own (else they spin at PPID 1 forever)
    (kill-orphan-transports))
  (log-line "CL bridge starting (config ~a) transports=[~{~a~^ ~}]"
            *config-path* *transports*)
  (unless (or *xmpp-on* *pp-on* *zulip-on*)
    (log-line "WARNING: no surface is live (transports=~s; pp needs [pp] enabled=true and base) — idling with nothing to serve"
              *transports*))
  ;; restore anything queued when a previous run died (see queue-sync)
  (setf *queue* (getf *state* :queue))
  ;; NOTE: reap AFTER connecting. reap-orphan may wait on an in-flight turn,
  ;; and running it first took gregor fully offline (no stanza reading, no
  ;; ping answers) until that turn ended — observed 2026-09-27.
  (baseline-watermarks)
  (let ((backoff 5))
    (loop
      ;; connect (or reconnect after any fatal error below). The reconnect
      ;; block matters: a failed CONNECT must skip the serve loop and RETRY.
      ;; The old `(return)` here returned from the whole loop -- and so ended
      ;; main and the process -- after a single failed connect, contradicting
      ;; its own "retry in ~ds" line. It also only caught `error`; broaden to
      ;; serious-condition (stack/heap exhaustion is a storage-condition, NOT
      ;; an error) so a bad parse cannot abort the process.
      (block reconnect
      (when *xmpp-on*
        (handler-case (progn (xmpp-connect) (setf backoff 5))
          (serious-condition (e)
            (log-line "connect failed: ~a — retry in ~ds" e backoff)
            (kill-transport)
            (setf *conn* nil)
            ;; Do NOT abandon the loop while pp can still serve. An xmpp-only
            ;; bridge skips the serve pass and retries; a DUAL bridge keeps
            ;; polling the habitat while xmpp retries in the background.
            (unless *pp-on*
              (sleep backoff)
              (setf backoff (min (* 2 backoff) 60))
              (return-from reconnect nil))
            (setf *main-next-xmpp-try* (+ (now) backoff))
            (setf backoff (min (* 2 backoff) 60)))))
      ;; reap runs once per outer-loop pass: after a connect when xmpp is
      ;; on, and immediately when it is off (there is no stream to starve).
      ;; While xmpp is DOWN but pp is serving, skip it: reap-orphan may wait
      ;; on an in-flight turn, which would stall the habitat poller.
      (when (or (not *xmpp-on*) *conn*) (reap-orphan))
      ;; serve until the stream dies
      (handler-case
          (progn
            (loop
              ;; 1. drain + dispatch xmpp stanzas (up to ~0.5s granularity).
              ;; This step is also the loop's only natural pace: with xmpp off
              ;; there is no blocking read, so the pp-poller branch below
              ;; sleeps explicitly. A pp-only bridge that fell through without
              ;; either would hot-spin a core.
              (cond ((and *xmpp-on* *conn*)
                     (let ((stanza (xmpp-next-stanza-with-timeout)))
                       (when stanza (dispatch-stanza stanza))))
                    (t (sleep 0.5)))
              ;; 2. keepalive whitespace ping every 60s
              (when (and *xmpp-on* *conn* (> (- (now) *main-last-keepalive*) 60))
                (setf *main-last-keepalive* (now))
                (xmpp-send " "))
              ;; 2b. XEP-0199 ping every *xmpp-ping-secs*: forces a
              ;; round-trip answer (pong or error iq) even when idle, so
              ;; *last-inbound* stays fresh on a healthy stream.
              (when (and *xmpp-on* *conn* (> (- (now) *main-last-xmpp-ping*) *xmpp-ping-secs*))
                (setf *main-last-xmpp-ping* (now))
                (xmpp-send (format nil "<iq id='keepalive~d' type='get'><ping xmlns='urn:xmpp:ping'/></iq>" (now))))
              ;; 2c. no inbound bytes for *xmpp-stale-secs* — not even
              ;; ping answers: the flow is dead (silently dropped
              ;; middlebox state). Raise through the normal error path
              ;; below, which closes the tunnel and reconnects.
              (when (and *xmpp-on* *conn* (> (- (now) *last-inbound*) *xmpp-stale-secs*))
                (error "xmpp stale: no inbound bytes in ~as — reconnecting" *xmpp-stale-secs*))
              ;; 2d. MUC self-heal: fire any due room rejoin (*muc-rejoin*)
              (when (and *xmpp-on* *conn*) (muc-rejoin-due))
              ;; 2e. xmpp enabled but disconnected — connect failed, or the
              ;; stream died while pp kept serving. Once the backoff has
              ;; elapsed, raise through the normal error path so the connect
              ;; block retries. Without this, a dual bridge that lost xmpp
              ;; would never re-attempt the stream.
              (when (and *xmpp-on* (null *conn*) (>= (now) *main-next-xmpp-try*))
                (error "xmpp reconnect due"))
              ;; 3. start a queued turn if none is running
              (when (and *queue* (not *turn*))
                (let ((item (first *queue*)))
                  (setf *queue* (rest *queue*))
                    (queue-sync)  ; remainder persisted; item now rides the turn
                  (let ((bodies (queue-flatten item)))
                    (cond ((and (= (length bodies) 1)
                                (string-equal (trim (first bodies)) "reset"))
                           (deliver-once (getf item :peer) (getf item :surface)
                                         "restarting the agent (kill + resume, ~60s)...")
                           (recover-agent)
                           (deliver-once (getf item :peer) (getf item :surface)
                                         "agent back online"))
                          (t
                           (let* ((surface (getf item :surface))
                                  (text (format nil "~{~a~^~%~}" bodies))
                                  (prompt (if (eq (reply-policy surface) :stream)
                                              text
                                              (concatenate 'string
                                                           (consolidate-prefix surface)
                                                           text))))
                             (run-turn (getf item :peer) surface prompt)))))))
              ;; 4. streaming surfaces: deliver narration as it flushes
              (when *turn* (ignore-errors (stream-poll nil)))
              ;; 5. pp dm poller
              (when *pp-on*
                (when (> (- (now) *main-last-pp-poll*) *pp-poll-secs*)
                  (setf *main-last-pp-poll* (now))
                  (pp-poll)))
                ;; 5a. zulip poller
                (when *zulip-on*
                  (when (> (- (now) *main-last-zulip-poll*) *zulip-poll-secs*)
                    (setf *main-last-zulip-poll* (now))
                    (ignore-errors (zulip-service))))
                ;; 5b. tuna inbox poller (public log, server-side cursor)
                (when *tuna-on*
                  (when (> (- (now) *main-last-tuna-poll*) *tuna-poll-secs*)
                    (setf *main-last-tuna-poll* (now))
                    (tuna-poll)))
              ;; 6. picker watcher
              (picker-watch)

              ;; 6b. detached child jobs: announce completions
              (when (> (- (now) *main-last-task-poll*) *task-poll-secs*)
                (setf *main-last-task-poll* (now))
                (ignore-errors (sync-tasks)))
              ;; 6c. deliver buffered job notices as one digest
              (when (and *notice-digest* *notice-digest-since*
                         (> (- (now) *notice-digest-since*)
                            *notice-digest-window*))
                (ignore-errors (flush-notices)))
              ;; 7. retry parked deliveries
              (when (getf *state* :parked)
                (when (> (- (now) *main-last-flush*) 30)
                  (setf *main-last-flush* (now))
                  (flush-parked)))))
        (serious-condition (e)
          (log-line "main loop error: ~a — reconnecting in ~ds" e backoff)
            (kill-transport)
            (setf *conn* nil)
          ;; Sleeping here is correct for an xmpp-only bridge (nothing else to
          ;; do). For a dual bridge it would starve the habitat poller for up
          ;; to 60s per failed reconnect, so park the retry time and let the
          ;; serve pass keep running pp while xmpp waits out the backoff.
          (if *pp-on*
              (setf *main-next-xmpp-try* (+ (now) backoff))
              (sleep backoff))
          (setf backoff (min (* 2 backoff) 60))))))))



(defun fatal-exit (e)
  "Log WHY the bridge is dying, with a backtrace, to stderr (-> bridge.err)
 and to bridge.log, then exit non-zero so the supervisor restarts us. Without
 this an aborted `sbcl --script` printed its backtrace only to the tmux pane,
 which is destroyed with the session -- every death was unexplained (2026-10-09)."
  (ignore-errors
    (format *error-output* "~&FATAL ~a: ~a~%" (timestamp-string) e))
  (ignore-errors
    (let ((bt (find-symbol "PRINT-BACKTRACE" "SB-DEBUG")))
      (when bt (funcall bt :stream *error-output* :count 60))))
  (ignore-errors (finish-output *error-output*))
  (ignore-errors (log-line "FATAL: ~a" e))
  (sb-ext:exit :code 1))

