(in-package :cl-user)

;;;; zulip.lisp -- the Zulip surface for the saguaro bridge.
;;;
;;;; Loaded by bridge.lisp after its config and transport sections; uses the
;;;; helpers defined there (cfg-str, json-parse, jget, run-capture, home-path,
;;;; log-line, trim, now) and nothing outside them.
;;;
;;;; The bot listens on an events queue, decides whether a message deserves a
;;;; turn (see ZULIP-RESPOND-P), and answers into the same stream and topic (or
;;;; the same direct message). Outside the open streams it only answers
;;;; mentions, messages that name it, and direct messages.

(defparameter *zulip-site* (cfg-str "zulip" "site"))
(defparameter *zulip-email* (cfg-str "zulip" "email"))
(defparameter *zulip-rc* (cfg-str "zulip" "zuliprc"))
(defparameter *zulip-streams* (cfg-list "zulip" "streams"))
(defparameter *zulip-open-streams* (cfg-list "zulip" "open_streams"))
(defparameter *zulip-name-words* (cfg-list "zulip" "name_words"))
(defparameter *zulip-reply-policy* (cfg-str "zulip" "reply_policy" "consolidate"))
(defparameter *zulip-poll-secs* (cfg-int "zulip" "poll_secs" 5))
(defparameter *zulip-chunk-chars* (cfg-int "zulip" "chunk_chars" 3000))
(defparameter *zulip-state-path* (home-path ".cache/saguaro-zulip-queue"))
(defparameter *zulip-netrc-path* (home-path ".cache/saguaro-zulip.netrc"))
(defparameter *zulip-on*
  (and (transport-on-p "zulip")
       (cfg-bool* "zulip" "enabled")
       (or *zulip-site* (cfg-str "zulip" "site" ""))
       (or *zulip-email* (cfg-str "zulip" "email" ""))
       *zulip-rc*))

;;; ---------------------------------------------------------------------
;;; credentials and HTTP
;;;
;;; The API key lives in a Zulip-generated rc file (0600) and never on a
;;; command line: it is copied once into a 0600 netrc that curl reads with
;;; --netrc-file, so it stays out of `ps` and out of the bridge log.
;;; ---------------------------------------------------------------------

(defun zulip-rc-field (name)
  "Value of NAME in the zuliprc, or NIL."
  (let ((text (and *zulip-rc* (read-file-string *zulip-rc*))))
    (when text
      (with-input-from-string (s text)
        (loop for line = (read-line s nil nil)
              while line
              do (let ((line (trim line)))
                   (unless (or (zerop (length line)) (eql (char line 0) #\[))
                     (let ((eq (position #\= line)))
                       (when (and eq (string-equal (trim (subseq line 0 eq)) name))
                         (return (trim (subseq line (1+ eq)))))))))))))

(defun zulip-site* () (or *zulip-site* (zulip-rc-field "site")))
(defun zulip-email* () (or *zulip-email* (zulip-rc-field "email")))

(defun zulip-host ()
  (let ((site (zulip-site*)))
    (when site
      (let* ((start (if (search "://" site) (+ 3 (search "://" site)) 0))
             (rest (subseq site start))
             (end (or (position #\/ rest) (length rest))))
        (subseq rest 0 end)))))

(defun zulip-ensure-netrc ()
  "Write the 0600 netrc curl authenticates with. Returns its path or NIL."
  (let ((key (zulip-rc-field "key"))
        (email (zulip-email*))
        (host (zulip-host)))
    (when (and key email host)
      (let ((body (format nil "machine ~a login ~a password ~a~%" host email key)))
        (with-open-file (out *zulip-netrc-path* :direction :output :if-exists :supersede
                                                :if-does-not-exist :create
                                                :external-format :utf-8)
          (write-string body out))
        (ignore-errors (sb-posix:chmod *zulip-netrc-path* #o600))
        *zulip-netrc-path*))))

(defun zulip-api (method path &optional params timeout)
  "Call the Zulip REST API. Returns the parsed reply, or NIL with a log line."
  (let* ((netrc (zulip-ensure-netrc))
         (url (concatenate 'string (zulip-site*) path))
         (argv (append (list (curl-bin) "-sS" "--max-time" (princ-to-string (or timeout 30)))
                       (when netrc (list "--netrc-file" netrc))
                       (list "-X" method)
                       (loop for (k . v) in params
                             append (list "--data-urlencode" (format nil "~a=~a" k v)))
                       (list url))))
    (multiple-value-bind (out err code) (run-capture argv (1+ (or timeout 30)))
      (cond
        ((not (zerop code))
         (log-line "zulip: ~a ~a failed (~a): ~a" method path code (trim err))
         nil)
        (t
         (handler-case
             (let ((reply (json-parse out)))
               (unless (equal (jget reply "result") "success")
                 (log-line "zulip: ~a ~a refused: ~a" method path
                           (or (jget reply "msg") (jget reply "code") (jget reply "result"))))
               reply)
           (error (e) (log-line "zulip: unparseable reply to ~a ~a: ~a" method path e) nil)))))))

;;; ---------------------------------------------------------------------
;;; queue state, so a restart does not drop what arrived while we were down
;;; ---------------------------------------------------------------------

(defparameter *zulip-state* nil)

(defun zulip-load-state ()
  (unless *zulip-state*
    (setf *zulip-state*
          (or (ignore-errors
                (with-open-file (in *zulip-state-path* :if-does-not-exist nil)
                  (when in (read in))))
              (list :queue nil :last-event-id -1 :topics nil)))))

(defun zulip-save-state ()
  (when *zulip-state*
    (ignore-errors
      (with-open-file (out *zulip-state-path* :direction :output :if-exists :supersede
                                                :if-does-not-exist :create)
        (let ((*print-readably* t) (*print-pretty* t))
          (write *zulip-state* :stream out))))))

(defun zulip-state (key) (zulip-load-state) (getf *zulip-state* key))
(defun (setf zulip-state) (value key) (zulip-load-state) (setf (getf *zulip-state* key) value))

;;; ---------------------------------------------------------------------
;;; identity: which senders are bots, which words name this one
;;; ---------------------------------------------------------------------

(defparameter *zulip-bot-ids* (make-hash-table :test #'equal))
(defparameter *zulip-bots-known-p* nil)

(defun zulip-fetch-users ()
  (let ((reply (zulip-api "GET" "/api/v1/users")))
    (when reply
      (clrhash *zulip-bot-ids*)
      (dolist (user (jget reply "members"))
        (when (eq (jget user "is_bot") :true)
          (setf (gethash (princ-to-string (jget user "user_id")) *zulip-bot-ids*) t)))
      (setf *zulip-bots-known-p* t))))

(defun zulip-bot-p (sender-id)
  (unless *zulip-bots-known-p* (zulip-fetch-users))
  (and sender-id (gethash (princ-to-string sender-id) *zulip-bot-ids*) t))

(defparameter *zulip-own-name* nil)

(defun zulip-own-name ()
  "The bot's full name, fetched once and kept."
  (unless *zulip-own-name*
    (let ((reply (zulip-api "GET" "/api/v1/users/me")))
      (setf *zulip-own-name* (or (and reply (jget reply "full_name")) ""))))
  *zulip-own-name*)

(defun zulip-name-words ()
  "Words that address this bot: configured, else its full name and login."
  (let* ((own (zulip-own-name))
         (mine (when (plusp (length own))
                 (uiop:split-string (string-downcase own) :separator " "))))
    (remove-duplicates
     (remove "" (append (mapcar #'string-downcase (or *zulip-name-words* mine))
                         (list (zulip-email-local (zulip-email*)))))
     :test #'string=)))

(defun zulip-email-local (email)
  (if (and email (position #\@ email))
      (subseq email 0 (position #\@ email))
      (or email "")))

(defun zulip-named-p (content)
  "True when CONTENT addresses this bot by name or by @-mention."
  (let ((text (string-downcase (or content ""))))
    (or (search "@**" text)
        (loop for word in (zulip-name-words)
              thereis (let ((from 0) (found nil))
                        (loop for at = (search word text :start2 from)
                              while at
                              do (let* ((end (+ at (length word)))
                                        (before (if (zerop at) #\Space (char text (1- at))))
                                        (after (if (>= end (length text)) #\Space (char text end))))
                                   (when (and (not (alphanumericp before))
                                              (not (alphanumericp after)))
                                     (setf found t)))
                                 (setf from (1+ at)))
                        found)))))

;;; ---------------------------------------------------------------------
;;; messages
;;; ---------------------------------------------------------------------

(defun zulip-flags (message)
  (let ((flags (jget message "flags")))
    (loop for flag in (if (listp flags) flags nil)
          when (stringp flag) collect (string-downcase flag))))

(defun zulip-direct-p (message) (equal (jget message "type") "direct"))

(defun zulip-stream-of (message)
  (let ((to (jget message "display_recipient")))
    (cond ((stringp to) to)
          ((listp to) nil)
          (t nil))))


(defun zulip-normalize (message)
  "One message event as a plist the policy and the delivery path share."
  (list :id (jget message "id")
        :sender (jget message "sender_email")
        :sender-name (jget message "sender_full_name")
        :sender-id (jget message "sender_id")
        :type (if (zulip-direct-p message) :direct :stream)
        :stream (zulip-stream-of message)
        :stream-id (jget message "stream_id")
        :topic (jget message "subject")
        :content (jget message "content")
        :flags (zulip-flags message)))

(defun zulip-peer (message)
  "The PEER string the bridge delivers to, encoding where the answer goes."
  (if (eq (getf message :type) :direct)
      (format nil "d|~a" (getf message :sender-id))
      (format nil "s|~a|~a" (getf message :stream) (getf message :topic))))

(defun zulip-split (string separator)
  "STRING split on SEPARATOR, empty fields kept."
  (let ((parts nil) (start 0))
    (loop
      (let ((at (position separator string :start start)))
        (if at
            (progn (push (subseq string start at) parts)
                   (setf start (1+ at)))
            (progn (push (subseq string start) parts)
                   (return (nreverse parts))))))))

(defun zulip-peer-target (peer)
  "PEER as (KIND FIELD...): d|USER-ID or s|STREAM|TOPIC."
  (zulip-split peer #\|))

(defun zulip-send (peer text)
  "Send TEXT where PEER says. Returns T when Zulip accepted it."
  (let* ((target (zulip-peer-target peer))
         (kind (first target))
         (stream (second target))
         (topic (third target))
         (reply (if (equal kind "d")
                    (zulip-api "POST" "/api/v1/messages"
                               (list (cons "type" "direct")
                                     (cons "to" (format nil "[~a]" stream))
                                     (cons "content" text)))
                    (zulip-api "POST" "/api/v1/messages"
                               (list (cons "type" "stream")
                                     (cons "to" (or stream ""))
                                     (cons "topic" (or topic ""))
                                     (cons "content" text))))))
    (if (and reply (equal (jget reply "result") "success"))
        (progn (log-line "zulip: delivered to ~a" peer) t)
        (progn (log-line "zulip: delivery to ~a failed" peer) nil))))

(defun zulip-deliver (peer text)
  "Bridge delivery entry: the whole text, chunked to stay clear of limits."
  (let ((chunks (chunk-text text *zulip-chunk-chars*)))
    (loop for chunk in chunks
          for last = (eq chunk (car (last chunks)))
          for ok = (zulip-send peer (if last chunk chunk))
          unless ok return nil
          finally (return t))))

;;; ---------------------------------------------------------------------
;;; the queue
;;; ---------------------------------------------------------------------

(defun zulip-register ()
  "Open a message queue and remember it. Returns the queue id or NIL."
  (let ((reply (zulip-api "POST" "/api/v1/register"
                          (list (cons "event_types" "[\"message\"]")
                                (cons "apply_markdown" "false")))))
    (when (and reply (equal (jget reply "result") "success"))
      (setf (zulip-state :queue) (jget reply "queue_id")
            (zulip-state :last-event-id) (or (jget reply "last_event_id") -1))
      (zulip-save-state)
      (log-line "zulip: queue opened")
      (zulip-state :queue))))

(defun zulip-poll-once ()
  "New messages since the last poll, oldest first. Re-registers on a lost queue."
  (let ((queue (zulip-state :queue)))
    (unless queue (setf queue (zulip-register)))
    (when queue
      (let* ((last-id (or (zulip-state :last-event-id) -1))
             (reply (zulip-api "GET"
                               (format nil "/api/v1/events?queue_id=~a&last_event_id=~a&dont_block=true"
                                       queue last-id)))
             (messages nil))
        (cond
          ((and reply (equal (jget reply "result") "success"))
           (loop for event in (jget reply "events")
                 do (setf (zulip-state :last-event-id) (or (jget event "id")
                                                           (zulip-state :last-event-id)))
                 when (and (equal (jget event "type") "message")
                           (jget event "message"))
                   do (push (zulip-normalize (jget event "message")) messages))
           (zulip-save-state)
           (nreverse messages))
          (t
           (log-line "zulip: queue lost or refused; opening a new one")
           (setf (zulip-state :queue) nil)
           (zulip-save-state)
           nil))))))

;;; ---------------------------------------------------------------------
;;; should it answer? the policy
;;; ---------------------------------------------------------------------

(defun zulip-open-stream-p (stream)
  (and stream (member stream *zulip-open-streams* :test #'string-equal)))

(defun zulip-topic-key (message)
  (and (eq (getf message :type) :stream)
       (getf message :stream)
       (format nil "~a|~a" (getf message :stream) (or (getf message :topic) ""))))

(defun zulip-followed-topic-p (message)
  (let ((key (zulip-topic-key message)))
    (and key (member key (zulip-state :topics) :test #'equal))))

(defun zulip-follow (message)
  (let ((key (zulip-topic-key message)))
    (when (and key (not (zulip-followed-topic-p message)))
      (setf (zulip-state :topics) (cons key (zulip-state :topics)))
      (zulip-save-state))))

(defun zulip-respond-p (message)
  "Return (values T REASON) when MESSAGE deserves a turn, NIL and the reason why not.

  Outside the open streams only a mention, the bot's own name, or a direct
  message starts a turn. Inside an open stream (ZZ_Agents) every message from
  a person does; a message from another bot still needs a mention or a name,
  which is what keeps two agents from answering each other forever."
  (let ((sender (getf message :sender))
        (content (getf message :content)))
    (cond
      ((and sender (string-equal sender (or (zulip-email*) ""))) (values nil :self))
      ((member "mentioned" (getf message :flags) :test #'string-equal) (values t :mentioned))
      ((zulip-named-p content) (values t :named))
      ((eq (getf message :type) :direct) (values t :direct))
      ((and (zulip-open-stream-p (getf message :stream))
            (not (zulip-bot-p (getf message :sender-id))))
       (values t :open-stream))
      ((and (zulip-followed-topic-p message)
            (not (zulip-bot-p (getf message :sender-id))))
       (values t :topic-followup))
      (t (values nil :unaddressed)))))

;;; ---------------------------------------------------------------------
;;; serving
;;; ---------------------------------------------------------------------

(defun zulip-prompt (message)
  "What the agent sees: who said it, where, and where an answer lands."
  (let ((sender (or (getf message :sender-name) (getf message :sender) "someone")))
    (format nil "~aZULIP message from ~a ~a~%~%~a"
            (consolidate-prefix :zulip)
            sender
            (if (eq (getf message :type) :direct)
                "(direct message; your reply goes back to them)"
                (format nil "in #~a > ~a (your reply goes to that stream and topic)"
                        (getf message :stream) (getf message :topic)))
            (or (getf message :content) ""))))

(defun zulip-service ()
  "Poll once and run a turn for each message the policy accepts."
  (dolist (message (zulip-poll-once))
    (let ((peer (zulip-peer message)))
      (multiple-value-bind (wanted reason) (zulip-respond-p message)
        (cond
          (wanted
           (log-line "zulip: answering ~a (~a) from ~a" peer reason (getf message :sender))
           (zulip-follow message)
           (run-turn peer :zulip (zulip-prompt message)))
          (t
           (log-line "zulip: skipping message ~a from ~a (~a)"
                     (getf message :id) (getf message :sender) reason)))))))
