;;;; say.lisp — one-shot senders over the bridge's own xmpp stack (2026-10-09).
;;;;
;;;; CL port of dm_send.py / muc_send.py / muc_history.py: same three CLIs,
;;;; but connect/auth/bind/send is the LIVE bridge's own machinery, loaded
;;;; as a library — not a second reimplementation in a second language
;;;; (that duplication is what slixmpp and the venv existed for).
;;;;
;;;; Usage:
;;;;   sbcl --script say.lisp dm TO_JID BODY|-         one-shot DM ('-' body on stdin)
;;;;   sbcl --script say.lisp muc ROOM_JID TEXT...     post to a configured room
;;;;   sbcl --script say.lisp history ROOM_JID [MAX]   recent room history (default 30)
;;;;
;;;; Contract, same as the Python originals:
;;;;   - random per-shot resource: the live bridge holds "autolith"; a
;;;;     second bind on that resource would kick the bridge off the server.
;;;;   - MUC joins run under muc_nick-say, never the live bridge's own
;;;;     nick: a same-JID rejoin under the bridge's nick would transfer
;;;;     (silently strip) its room occupancy - the server raises no
;;;;     conflict for the same bare JID.
;;;;   - ROOM must be listed under [bridge] mucs in config.toml; that list
;;;;     is the authorization boundary.
;;;;   - exit 0 = the stanza was handed to the stream; delivery is NOT
;;;;     confirmed. exit 1 = anything failed.
;;;;
;;;; One-shot bootstrap: bridge.lisp runs (main) on load unless
;;;; SAGUARO_NO_MAIN is set, so the guard goes up BEFORE the load. The
;;;; require comes first so sb-posix:setenv exists to set it.

(require :sb-posix)
(sb-posix:setenv "SAGUARO_NO_MAIN" "1" 1)

;; say.lisp ships next to bridge.lisp in harness/.
(load (merge-pathnames "bridge.lisp"
                       (or (and *load-truename*
                                (make-pathname :defaults *load-truename*
                                               :name nil :type nil))
                           #p"/home/al/saguaro-live/harness/")))

;; real randomness for per-shot resources
(setf *random-state* (make-random-state t))

(defun say-resource ()
  (format nil "say-~d-~d" (get-universal-time) (random 1000000)))

(defun say-resource-of (jid)
  "Nickname part of room@service/nick (\"\" when there is no slash)."
  (let ((slash (and jid (position #\/ jid :from-end t))))
    (if slash (subseq jid (1+ slash)) "")))

(defun say-bind ()
  "xmpp-bind on a RANDOM per-shot resource. Deliberately not bridge.lisp's
   xmpp-bind: that binds the configured \"autolith\" resource, which the
   live bridge holds — binding it again would kick the bridge offline."
  (let ((resource (say-resource)))
    (xmpp-send "<iq id='bind1' type='set'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>"
               resource
               "</resource></bind></iq>")
    (loop
      (let ((stanza (xmpp-next-stanza)))
        (cond ((null stanza) (error "xmpp: stream closed during bind"))
              ((and (xml-stanza-name-is stanza "iq")
                    (search "<bind" stanza))
               (return (xml-element-text stanza "jid"))))))))

(defun say-connect ()
  "One-shot connection: tunnel, PLAIN auth, random-resource bind, bare
   presence. Deliberately not xmpp-connect, which also joins every
   configured room with maxstanzas=0 — a one-shot joins at most one room,
   the one it was asked about."
  (let* ((jid (cfg-str "bridge" "jid"))
         (host (subseq jid (1+ (position #\@ jid))))
         (password (trim (or (read-file-string (cfg-str "bridge" "password_file")) "")))
         (p (open-tunnel host 5222)))
    (setf *conn* (list :proc p :host host :jid jid :password password
                       :in (sb-ext:process-output p)
                       :out (sb-ext:process-input p)
                       :buf ""))
    (xmpp-stream-header)
    (xmpp-authenticate)
    (say-bind)
    (xmpp-send "<presence><priority>0</priority></presence>")))

(defun say-close ()
  "Clean one-shot exit: end the stream, then the full kill-transport
teardown (stdin EOF, SIGTERM backstop, bounded waits, process-close).
process-close alone just closes the pipes and leaks the s_client child
(PPID 1, unreaped) - one orphan per send, the same bug bridge.lisp grew
out of 2026-10-09 (commit 7ba7fc4); say.lisp loads bridge.lisp as a
library, so the real teardown is already in this image."
  (when *conn*
    (ignore-errors (xmpp-send "</stream:stream>"))
    (kill-transport)
    (setf *conn* nil)))

(defun say-delay-stamp (stanza)
  "History stamp from XEP-0203 <delay stamp='...'> (legacy jabber:x:delay
   falls through the same search), or nil when the message is not a replay."
  (let ((pos (or (search "<delay" stanza) (search "jabber:x:delay" stanza))))
    (when pos
      (let* ((key "stamp='")
             (p (search key stanza :start2 pos)))
        (when p
          (let* ((start (+ p (length key)))
                 (end (position #\' stanza :start start)))
            (when end (subseq stanza start end))))))))

(defun say-hhmm (stamp)
  "HH:MM (UTC) out of a delay stamp, --:-- when there is none."
  (let ((t- (and stamp (position #\T stamp))))
    (if (and t- (>= (length stamp) (+ t- 6)))
        (subseq stamp (+ t- 1) (+ t- 6))
        "--:--")))

(defun say-join-once (room nick maxstanzas quiet-secs)
  "Send the join presence for ROOM as NICK and read until the join settles:
   self-presence (muc#user status 110) plus QUIET-SECS of no further
   stanzas, so replayed history has fully landed. Hard deadline 20s.
   Returns (values :ok history) with history as (hh:mm nick body) triplets
   in arrival order — delayed messages only; live traffic during the
   window is not history — or (values :conflict nil) when the server
   rejected the nickname (another say one-shot may hold it)."
  (xmpp-send (format nil "<presence to='~a/~a'><x xmlns='http://jabber.org/protocol/muc'><history maxstanzas='~d'/></x></presence>"
                     (xml-escape room) (xml-escape nick) maxstanzas))
  (let ((hist '()) (self-seen nil) (last (now)) (deadline (+ (now) 20)))
    (loop
      (when (> (now) deadline)
        (error "join timeout: no self-presence from ~a within 20s" room))
      (let ((stanza (handler-case (xmpp-next-stanza-with-timeout)
                      (error (e)
                        (error "xmpp stream closed while joining ~a: ~a" room e)))))
        (cond ((null stanza)
               (when (and self-seen (> (- (now) last) quiet-secs))
                 (return)))
              (t
               (setf last (now))
               (cond
                 ((xml-stanza-name-is stanza "presence")
                  (cond ((and (search "muc#user" stanza)
                              (or (search "code='110'" stanza)
                                  (search "code=\"110\"" stanza)))
                         (setf self-seen t))
                        ((and (or (search "type='error'" stanza)
                                  (search "type=\"error\"" stanza))
                              (or (search "<conflict" stanza)
                                  (search "409" stanza)))
                         (return-from say-join-once :conflict))))
                 ((xml-stanza-name-is stanza "message")
                  (let* ((stamp (say-delay-stamp stanza))
                         (from (xml-attr stanza "from"))
                         (body (trim (or (xml-element-text stanza "body") ""))))
                    (when (and stamp
                               from
                               (>= (length from) (1+ (length room)))
                               (string= from room :end1 (length room))
                               (eql (char from (length room)) #\/)
                               (plusp (length body)))
                      (push (list (say-hhmm stamp)
                                  (say-resource-of from)
                                  body)
                            hist)))))))))
    (values :ok (nreverse hist))))

(defun say-join (room maxstanzas quiet-secs)
  "Join ROOM under muc_nick-say - deliberately NOT the configured muc
nick: the live bridge occupies that nick, and a same-JID rejoin under it
would transfer the room occupancy away from the bridge (the server
raises no conflict for the same bare JID). On a conflict (another say
one-shot holds the nick), retry once as nick-say-2. Returns (values
nick history)."
  (let* ((base (cfg-str "bridge" "muc_nick" "agent"))
         (nick (concatenate 'string base "-say")))
    (multiple-value-bind (r hist)
        (say-join-once room nick maxstanzas quiet-secs)
      (if (eq r :ok)
          (values nick hist)
          (let ((alt (concatenate 'string nick "-2")))
            (multiple-value-bind (r2 hist2)
                (say-join-once room alt maxstanzas quiet-secs)
              (if (eq r2 :ok)
                  (values alt hist2)
                  (error "nickname conflict in ~a (tried ~a and ~a)"
                         room nick alt))))))))

(defun say-stdin-all ()
  (with-output-to-string (o)
    (loop for line = (read-line *standard-input* nil nil)
          while line
          do (write-line line o))))

(defun say-usage ()
  (format t "usage:~%")
  (format t "  sbcl --script say.lisp dm TO_JID BODY|-         one-shot DM ('-' reads stdin)~%")
  (format t "  sbcl --script say.lisp muc ROOM_JID TEXT...     post to a configured room~%")
  (format t "  sbcl --script say.lisp history ROOM_JID [MAX]   recent room history (default 30)~%"))

(defun say-authorized-room-p (room)
  "ROOM must be listed under [bridge] mucs — that list is the
   authorization boundary (same rule as the Python senders)."
  (let ((mucs (cfg-list "bridge" "mucs")))
    (or (member room mucs :test #'string=)
        (progn (format t "room ~a not in config.toml mucs: ~{~a~^, ~}~%" room mucs)
               nil))))

(defun say-dm (to body)
  (cond ((or (not to) (not (position #\@ to)) (not body))
         (say-usage) nil)
        (t (let ((text (if (string= body "-") (say-stdin-all) body)))
             (unless (plusp (length (trim text)))
               (say-usage)
               (return-from say-dm nil))
             (say-connect)
             (xmpp-send (format nil "<message to='~a' type='chat'><body>~a</body></message>"
                                (xml-escape to) (xml-escape text)))
             (sleep 1.5)                       ; let the stanza flush
             (format t "sent DM to ~a (~d chars)~%" to (length text))
             t))))

(defun say-muc (room parts)
  (cond ((or (not room) (not parts))
         (say-usage) nil)
        ((not (say-authorized-room-p room)) nil)
        (t (let ((text (string-trim '(#\Space #\Tab #\Return #\Newline)
                                    (format nil "~{~a~^~%~}" parts))))
             (unless (plusp (length text))
               (say-usage)
               (return-from say-muc nil))
             (say-connect)
             (say-join room 0 1.0)
             (xmpp-send (format nil "<message to='~a' type='groupchat'><body>~a</body></message>"
                                (xml-escape room) (xml-escape text)))
             (sleep 0.5)                       ; let the stanza flush
             (format t "sent to ~a~%" room)
             t))))

(defun say-history (room maxst)
  (cond ((not room) (say-usage) nil)
        ((not (say-authorized-room-p room)) nil)
        (t (say-connect)
           (multiple-value-bind (nick hist) (say-join room maxst 1.5)
             (declare (ignore nick))
             (dolist (h hist)
               (format t "[~a] ~a: ~a~%" (first h) (second h) (third h)))
             (format t "== ~a: ~d history message(s) (maxstanzas=~d)~%"
                     room (length hist) maxst)
             t))))

(let* ((args (rest sb-ext:*posix-argv*))
       (cmd (first args))
       (ok (handler-case
               (cond ((equal cmd "dm")
                      (say-dm (second args) (third args)))
                     ((equal cmd "muc")
                      (say-muc (second args) (rest (rest args))))
                     ((equal cmd "history")
                      (let ((n (and (third args)
                                    (ignore-errors
                                     (parse-integer (third args) :junk-allowed t)))))
                        (say-history (second args) (if (and n (plusp n)) n 30))))
                     (t (say-usage) nil))
             (error (e)
               (format t "failed: ~a~%" e)
               nil))))
  (say-close)
  (sb-ext:exit :code (if ok 0 1)))
