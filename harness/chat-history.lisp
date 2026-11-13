;;;; chat-history.lisp — read XMPP chat history from the SERVER (XEP-0313 MAM).
;;;;
;;;; One-shot, like say.lisp: connect, ask, print, exit. Nothing is cached or
;;;; logged locally; the rows come from the account's archive (DMs) or the
;;;; room's archive (MUC), so a read reflects what the server holds.
;;;;
;;;;   sbcl --script chat-history.lisp dm PEER_JID [MAX]     last MAX DMs with PEER (default 20)
;;;;   sbcl --script chat-history.lisp room ROOM_JID [MAX]   last MAX messages in ROOM
;;;;
;;;; ROOM must be listed under [bridge] mucs in config.toml, the same
;;;; authorization boundary say.lisp uses. Output is one line per message,
;;;; oldest first: "[HH:MM] nick: body", then a count line. Exit 0 = the query
;;;; completed (a room with no archive still exits 0 and says 0 messages).

(require :sb-posix)
(sb-posix:setenv "SAGUARO_NO_MAIN" "1" 1)

(load (merge-pathnames "bridge.lisp"
                       (or (and *load-truename*
                                (make-pathname :defaults *load-truename*
                                               :name nil :type nil))
                           #p"/home/al/saguaro-live/harness/")))

(setf *random-state* (make-random-state t))

(defun ch-attr (stanza name &optional (after 0))
  "Value of single-quoted attribute NAME at or after offset AFTER, or NIL.
   The offset matters for MAM results: the outer <message> carries the archive
   address, the forwarded inner <message> carries the real sender."
  (let* ((key (concatenate 'string name "='"))
         (p (search key stanza :start2 after)))
    (when p
      (let ((start (+ p (length key))))
        (subseq stanza start (position #\' stanza :start start))))))

(defun ch-connect ()
  "Tunnel, PLAIN auth, random-resource bind, bare presence. Same contract as
   say.lisp: never bind the live bridge's resource."
  (let* ((jid (cfg-str "bridge" "jid"))
         (host (subseq jid (1+ (position #\@ jid))))
         (password (trim (or (read-file-string (cfg-str "bridge" "password_file")) "")))
         (p (open-tunnel host 5222)))
    (setf *conn* (list :proc p :host host :jid jid :password password
                       :in (sb-ext:process-output p) :out (sb-ext:process-input p)
                       :buf ""))
    (xmpp-stream-header)
    (xmpp-authenticate)
    (xmpp-send (format nil "<iq id='chbind' type='set'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>history-~d</resource></bind></iq>"
                       (random 1000000)))
    (loop (let ((s (xmpp-next-stanza)))
            (cond ((null s) (error "xmpp: stream closed during bind"))
                  ((and (xml-stanza-name-is s "iq") (search "id='chbind'" s)) (return)))))
    (xmpp-send "<presence><priority>0</priority></presence>")))

(defun ch-close ()
  (when *conn*
    (ignore-errors (xmpp-send "</stream:stream>"))
    (kill-transport)
    (setf *conn* nil)))

(defun ch-stamp (stanza)
  "HH:MM (UTC) from the forwarded delay stamp; --:-- when absent."
  (let* ((sp (search "stamp='" stanza))
         (t- (and sp (position #\T stanza :start (+ sp 7)))))
    (if (and t- (>= (length stanza) (+ t- 6)))
        (subseq stanza (1+ t-) (+ t- 6))
        "--:--")))

(defun ch-nick (from)
  (let ((slash (and from (position #\/ from :from-end t))))
    (or (and slash (subseq from (1+ slash))) from "?")))

(defun ch-mam (target with max)
  "One MAM page. TARGET nil means our own archive; WITH filters to one peer."
  (let* ((id (format nil "mam~d" (random 1000000)))
         (fields (with-output-to-string (f)
                   (format f "<field var='FORM_TYPE' type='hidden'><value>urn:xmpp:mam:2</value></field>")
                   (when with
                     (format f "<field var='with'><value>~a</value></field>" (xml-escape with)))))
         (rows '()))
    (xmpp-send (format nil "<iq id='~a' type='set'~@[ to='~a'~]><query xmlns='urn:xmpp:mam:2'><x xmlns='jabber:x:data' type='submit'>~a</x><set xmlns='http://jabber.org/protocol/rsm'><max>~d</max><before/></set></query></iq>"
                       id target fields max))
    (loop
      for s = (xmpp-next-stanza)
      do (cond
           ((null s) (format t "stream closed before the MAM answer~%") (return))
           ((xml-stanza-name-is s "message")
            (let ((body (xml-element-text s "body"))
                   (from (ch-attr s "from" (or (search "<forwarded" s) 0))))
              (when (and body (plusp (length (trim body))))
                (push (list (ch-stamp s) from body) rows))))
           ((and (xml-stanza-name-is s "iq") (search (format nil "id='~a'" id) s))
            (when (search "type='error'" s)
              (format t "MAM refused: ~a~%"
                      (or (xml-element-text s "text")
                          (subseq s 0 (min 300 (length s))))))
            (return))))
      (setf rows (nreverse rows))
      (dolist (row rows)
        (format t "[~a] ~a: ~a~%" (first row) (ch-nick (second row)) (third row)))
      (format t "== ~d message(s) from ~a~%"
              (length rows) (or target "the account archive"))))

(defun ch-room-p (room)
  (or (member room (cfg-list "bridge" "mucs") :test #'string=)
      (progn (format t "room ~a not in config.toml mucs~%" room) nil)))

(let* ((args sb-ext:*posix-argv*)
       (verb (second args))
       (target (third args))
       (max (or (and (fourth args) (parse-integer (fourth args) :junk-allowed t)) 20)))
  (cond
    ((and verb target (string= verb "dm"))
     (ch-connect)
     (unwind-protect (ch-mam nil target max) (ch-close)))
    ((and verb target (string= verb "room") (ch-room-p target))
     (ch-connect)
     (unwind-protect (ch-mam target nil max) (ch-close)))
    (t
     (format t "usage:~%")
     (format t "  sbcl --script chat-history.lisp dm PEER_JID [MAX]~%")
     (format t "  sbcl --script chat-history.lisp room ROOM_JID [MAX]~%"))))
