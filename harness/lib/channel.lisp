;;;; channel.lisp -- one channel per surface and peer.
;;;;
;;;; A channel is an autolith conversation the bridge addresses by
;;;; (surface, peer): :xmpp-private + alice@example.org, :xmpp-group + a room,
;;;; :pp-dm + a habitat user, :zulip + a stream#topic or DM peer, :tuna-inbox +
;;;; a peer. Each one has its own transcript, its own watermarks and its own
;;;; turn queue, so two peers can be answered at the same time without their
;;;; context or their replies mixing.
;;;;
;;;; Two engines, picked by [channels] engine:
;;;;
;;;;   "channels"  each channel is its own world-server session. The bridge opens
;;;;               one with `autolith --detached` on first contact, finds its
;;;;               session in `lg status --sexp`, submits with `lg tell` and
;;;;               reads that conversation's directory.
;;;;   "legacy"    every surface shares the one conversation named in
;;;;               [autolith] conv, which is what the bridge did before
;;;;               2026-11-13. Use it on a box without a world server.
;;;;
;;;; The registry (key -> conversation) lives in ~/.cache/saguaro-channels.sexp,
;;;; so a restart reattaches to the same channel instead of opening a second one
;;;; for a peer that already has history.

(defpackage :sg.channel
  (:use :cl :sg.core :sg.autolith)
  (:export
   #:*ENGINE*
   #:*REGISTRY*
   #:CHANNELS-ENGINE-P
   #:CHANNEL-KEY
   #:CHANNEL-RECORD
   #:CHANNEL-ENSURE
   #:CHANNEL-CREATE
   #:CHANNEL-REOPEN
   #:CHANNEL-STATUS
   #:CHANNEL-SESSION
   #:CHANNEL-IDLE-P
   #:CHANNEL-SUBMIT
   #:RUN-CHANNEL-TURN
   #:CHANNEL-QUEUE-SIZE))
(in-package :sg.channel)

(defparameter *engine* (or (cfg-str "channels" "engine") "channels")
  "\"channels\" for one world-server session per channel, \"legacy\" for the
single shared conversation the bridge used before 2026-11-13.")

(defparameter *registry-path* (home-path ".cache/saguaro-channels.sexp"))

(defparameter *registry* nil)

(defparameter *registry-lock* (sb-thread:make-mutex :name "saguaro-channels"))

(defparameter *create-timeout* (max 5 (cfg-int "channels" "create_timeout_secs" 60)))

(defparameter *permissions* (cfg-str "channels" "permissions")
  "When set, passed as --permissions to a channel this bridge opens.")

(defun channels-engine-p ()
  (and (stringp *engine*) (string-equal *engine* "channels")))

;;; ---------------------------------------------------------------------
;;; channel identity
;;; ---------------------------------------------------------------------

(defun normalize-peer (surface peer)
  "Peer half of a channel key. XMPP peers are bare JIDs: the resource names one
client of the same person, not a second conversation."
  (let ((p (string-downcase (trim (or peer "")))))
    (if (member surface '(:xmpp-private :xmpp-group) :test #'eq)
        (let ((slash (position #\/ p)))
          (if slash (subseq p 0 slash) p))
        p)))

(defun channel-key (surface peer)
  (format nil "~(~a~):~a" surface (normalize-peer surface peer)))

;;; ---------------------------------------------------------------------
;;; registry
;;; ---------------------------------------------------------------------

(defun registry-ensure ()
  (or *registry*
      (setf *registry*
            (sb-thread:with-mutex (*registry-lock*)
              (or (and (probe-file *registry-path*)
                       (ignore-errors
                         (with-open-file (in *registry-path*)
                           (read in nil nil))))
                  '())))))

(defun registry-save ()
  (sb-thread:with-mutex (*registry-lock*)
    (ignore-errors
      (with-open-file (out *registry-path* :direction :output :if-exists :supersede
                                           :if-does-not-exist :create)
        (let ((*print-pretty* t))
          (prin1 *registry* out)
          (terpri out))))))

(defun channel-record (key)
  "The registry record for KEY, or NIL."
  (find key (registry-ensure) :key (lambda (r) (getf r :key)) :test #'string=))

(defun channel-remember (record)
  (sb-thread:with-mutex (*registry-lock*)
    (setf *registry*
          (cons record (remove (getf record :key) *registry*
                               :key (lambda (r) (getf r :key)) :test #'string=))))
  (registry-save)
  record)

;;; ---------------------------------------------------------------------
;;; status
;;; ---------------------------------------------------------------------

(defun status-records ()
  (ignore-errors (al-status-records)))

(defun channel-status (channel)
  "The `lg status` record for CHANNEL, or NIL when its session is gone."
  (when channel
    (let ((session (getf channel :session))
          (conversation (getf channel :conversation)))
      (find-if (lambda (r)
                 (or (and session (equal (getf r :session) session))
                     (and conversation (equal (getf r :conversation) conversation))))
               (status-records)))))

(defun channel-session (channel)
  "Session to `lg tell`. For a channel session this is the conversation id."
  (let ((status (channel-status channel)))
    (or (and status (getf status :session))
        (getf channel :session)
        (getf channel :conversation))))

(defun channel-idle-p (channel)
  (let ((status (channel-status channel)))
    (and status (getf status :idle))))

(defun new-status-record (before)
  "A status record whose session was not in BEFORE."
  (let ((old (mapcar (lambda (r) (getf r :session)) before)))
    (find-if (lambda (r)
               (and (getf r :conversation)
                    (not (member (getf r :session) old :test #'equal))))
             (status-records))))

(defun await-new-record (before &optional (tries 20))
  (loop repeat tries
        for found = (new-status-record before)
        when found return found
        do (sleep 0.5)))

;;; ---------------------------------------------------------------------
;;; opening channels
;;; ---------------------------------------------------------------------

(defun create-args ()
  (append (list *al-bin* "--detached")
          (when (and *permissions* (plusp (length *permissions*)))
            (list "--permissions" *permissions*))))

(defun channel-create (key &key title)
  "Open a world-server channel for KEY. Returns its registry record or NIL."
  (unless (channels-engine-p) (return-from channel-create nil))
  (let ((before (status-records)))
    (multiple-value-bind (out err code) (run-capture (create-args) *create-timeout*)
      (declare (ignore err))
      (unless (zerop code)
        (log-line "channel: create failed for ~a (~a): ~a" key code (trim out))
        (return-from channel-create nil))
      (let ((record (await-new-record before)))
        (unless record
          (log-line "channel: opened ~a but no new session appeared in lg status" key)
          (return-from channel-create nil))
        (log-line "channel: opened ~a -> conversation ~a" key (getf record :conversation))
        (channel-remember (list :key key :title title
                                :conversation (getf record :conversation)
                                :session (getf record :session)
                                :created (now)))))))

(defun channel-reopen (key)
  "Reattach the recorded conversation for KEY after a world-server restart."
  (let ((channel (channel-record key)))
    (when (and channel (getf channel :conversation))
      (let ((before (status-records)))
        (multiple-value-bind (out err code)
            (run-capture (list *al-bin* "open" (getf channel :conversation) "--detached")
                         *create-timeout*)
          (declare (ignore err))
          (unless (zerop code)
            (log-line "channel: reopen ~a failed (~a): ~a" key code (trim out))
            (return-from channel-reopen nil))
          (let ((record (await-new-record before)))
            (when record
              (channel-remember (list :key key :title (getf channel :title)
                                      :conversation (getf channel :conversation)
                                      :session (getf record :session)
                                      :created (getf channel :created)))
              (log-line "channel: reattached ~a as session ~a" key (getf record :session))
              t)))))))

(defun channel-ensure (surface peer &key title)
  "The channel for (SURFACE, PEER), opening or reattaching it when needed."
  (let* ((key (channel-key surface peer))
         (channel (channel-record key)))
    (cond ((not (channels-engine-p))
           ;; legacy: every surface shares the one configured conversation
           (or channel
               (channel-remember (list :key key :title title :conversation *al-conv*
                                       :session nil :legacy-p t :created (now)))))
          ((and channel (channel-status channel)) channel)
          ((and channel (getf channel :conversation) (channel-reopen key))
           (channel-record key))
          (t (channel-create key :title title)))))

(defun channel-submit (channel text)
  "Send TEXT to CHANNEL as the person. Returns T when the call was made."
  (let ((session (channel-session channel)))
    (when session
      (al-tell session text)
      t)))

;;; ---------------------------------------------------------------------
;;; per-channel turn queues
;;;
;;; A channel runs one turn at a time and different channels run in parallel,
;;; which is the point of giving each peer its own channel: a 40 minute turn for
;;; one peer no longer holds the queue for everyone else.
;;; ---------------------------------------------------------------------

(defparameter *workers* (make-hash-table :test 'equal))
(defparameter *workers-lock* (sb-thread:make-mutex :name "saguaro-channel-workers"))

(defun make-worker (key)
  (list :key key
        :lock (sb-thread:make-mutex :name key)
        :waitqueue (sb-thread:make-waitqueue :name key)
        :queue '()
        :thread nil))

(defun worker-for (key)
  (or (gethash key *workers*)
      (setf (gethash key *workers*) (make-worker key))))

(defun channel-queue-size (key)
  (let ((worker (gethash key *workers*)))
    (and worker (length (getf worker :queue)))))

(defun worker-loop (worker)
  (let ((lock (getf worker :lock))
        (waitqueue (getf worker :waitqueue)))
    (loop
      (let ((job nil))
        (sb-thread:with-mutex (lock)
          (loop while (null (getf worker :queue))
                do (sb-thread:condition-wait waitqueue lock))
          (setf job (pop (getf worker :queue))))
        (let ((*turn* nil)
              (*reap-peer* nil)
              (*no-text-nudged* nil)
              (*file-cache* (make-hash-table :test #'equal)))
          (handler-case (funcall job)
            (error (e)
              (log-line "channel ~a turn failed: ~a" (getf worker :key) e))))))))

(defun enqueue-turn (key job)
  (let ((worker (worker-for key)))
    (sb-thread:with-mutex ((getf worker :lock))
      (setf (getf worker :queue) (nconc (getf worker :queue) (list job))))
    (sb-thread:with-mutex (*workers-lock*)
      (unless (getf worker :thread)
        (setf (getf worker :thread)
              (sb-thread:make-thread (lambda () (worker-loop worker))
                                     :name (format nil "channel ~a" key)))))
    (sb-thread:condition-broadcast (getf worker :waitqueue))
    key))

(defun run-channel-turn (peer surface prompt)
  "Queue PROMPT as a turn on the channel for (SURFACE, PEER).

The caller returns at once; replies arrive through the surface's registered
sender, which is what every adapter already delivers through."
  (let ((channel (channel-ensure surface peer)))
    (when channel
      (enqueue-turn (getf channel :key)
                    (lambda ()
                      (run-turn peer surface prompt
                                :session (channel-session channel)
                                :conversation (getf channel :conversation))))
      channel)))
