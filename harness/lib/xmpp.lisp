;;;; xmpp.lisp -- the XMPP transport: the openssl s_client byte tunnel,

;;;; stream parsing, SASL and bind, MUC join and rejoin, stanza dispatch,
;;;; and the two XMPP surfaces (:xmpp-private, :xmpp-group).

(defpackage :SG.XMPP
  (:use :CL :SG.CORE :SG.AUTOLITH)
  (:export
   #:*XMPP-ON*
   #:*CONN*
   #:XML-ESCAPE
   #:XML-UNESCAPE
   #:ENTITY-VALUE
   #:OPEN-TUNNEL
   #:*OPENSSL-LAST-ERROR*
   #:KILL-TRANSPORT
   #:KILL-ORPHAN-TRANSPORTS
   #:XMPP-STREAM-HEADER
   #:XMPP-CONNECT
   #:XMPP-SEND
   #:XMPP-AUTHENTICATE
   #:XMPP-BIND
   #:XMPP-JOIN-MUC
   #:XMPP-POLL-NONBLOCKING
   #:XMPP-NEXT-STANZA
   #:EXTRACT-STANZA
   #:XML-STANZA-NAME
   #:XML-STANZA-NAME-IS
   #:XML-ATTR
   #:XML-INNER-TEXT
   #:XML-ELEMENT-TEXT
   #:XMPP-SEND-STATE
   #:*TYPING-REFRESH-SECS*
   #:XMPP-SEND-MESSAGE
   #:*QUEUE*
   #:STANZA-ALLOWED-P
   #:*MUC-REJOIN*
   #:MUC-STATUS-CODES
   #:MUC-HEAL-DELAY
   #:MUC-SCHEDULE-REJOIN
   #:MUC-CLEAR-REJOIN
   #:MUC-REJOIN-DUE
   #:DISPATCH-STANZA
   #:HANDLE-GROUP-MESSAGE
   #:REMOVE-MENTION
   #:HANDLE-DM
   #:QUEUE-SYNC
   #:ENQUEUE
   #:QUEUE-FLATTEN
   #:*TASK-POLL-SECS*   #:*LAST-INBOUND*
   #:XMPP-NEXT-STANZA-WITH-TIMEOUT
))
(in-package :SG.XMPP)


(defparameter *xmpp-on* (transport-on-p "xmpp"))


;;; ---------------------------------------------------------------------
;;; xmpp client — openssl s_client tunnel + streaming stanza reader
;;;
;;; /usr/bin/openssl s_client -quiet -starttls xmpp performs the TLS
;;; upgrade; we speak plain XMPP over its stdin/stdout pipes.
;;; ---------------------------------------------------------------------

(defparameter *conn* nil)
;; (:proc .. :in .. :out .. :buf ".." :jid .. :host .. :password ..)
;; Last time ANY byte arrived from the tunnel (stanza, pong, whitespace),
;; refreshed by every read path. A stream with no inbound bytes for
;; *xmpp-stale-secs* is dead even if TCP still says ESTABLISHED.
(defparameter *last-inbound* (get-universal-time))

(defun xml-escape (s)
  (with-output-to-string (o)
    (loop for ch across s
          do (case ch
               (#\& (write-string "&amp;" o))
               (#\< (write-string "&lt;" o))
               (#\> (write-string "&gt;" o))
               (#\" (write-string "&quot;" o))
               (#\' (write-string "&apos;" o))
               (t (write-char ch o))))))

(defun xml-unescape (s)
  (with-output-to-string (o)
    (let ((i 0) (n (length s)))
      (loop while (< i n)
            do (let ((ch (char s i)))
                 (if (eql ch #\&)
                     (let ((semi (position #\; s :start i :end (min n (+ i 12)))))
                       (if semi
                           (let ((dec (entity-value (subseq s (1+ i) semi))))
                             (if dec
                                 (progn (write-string dec o)
                                        (setf i (1+ semi)))
                                 (progn (write-char ch o) (incf i))))
                           (progn (write-char ch o) (incf i))))
                     (progn (write-char ch o) (incf i))))))))

(defun entity-value (ent)
  "Replacement text for an XML entity (without & and ;) or nil."
  (cond ((string= ent "amp") "&")
        ((string= ent "lt") "<")
        ((string= ent "gt") ">")
        ((string= ent "quot") "\"")
        ((string= ent "apos") "'")
        ((and (plusp (length ent)) (eql (char ent 0) #\#))
         (ignore-errors
          (string (code-char
                   (if (eql (char ent 1) #\x)
                       (parse-integer (subseq ent 2) :radix 16 :junk-allowed t)
                       (parse-integer (subseq ent 1) :junk-allowed t))))))
        (t nil)))

(defparameter *openssl-last-error* nil)

(defun open-tunnel (host port)
  "Spawn /usr/bin/openssl s_client -starttls xmpp and use its stdin/stdout
as a (TLS-backed) byte pipe. stderr is drained on a thread so a chatty
openssl can never fill the pipe and block the tunnel."
  (let* ((p (ignore-errors
             (sb-ext:run-program
              "/usr/bin/openssl"
              (list "s_client" "-quiet" "-starttls" "xmpp"
                    "-connect" (format nil "~a:~a" host port))
              :input :stream :output :stream :error :stream
              :wait nil :search t)))
         (err (and p (sb-ext:process-error p))))
    (unless p (error "openssl spawn failed"))
    (when err
      (sb-thread:make-thread
       (lambda ()
         (ignore-errors
          (loop for line = (read-line err nil nil)
                while line
                do (setf *openssl-last-error* line))))
       :name "openssl-stderr"))
    p))

(defun kill-transport ()
  "Tear down the s_client child for real: stdin EOF (openssl exits on it),
then SIGTERM as a backstop, bounded waits, and only then process-close.
process-close alone just closes the pipes and leaks the child (PPID 1,
unreaped) — one orphan per reconnect/bounce/crash, observed 2026-10-09."
  (let ((p (and *conn* (getf *conn* :proc))))
    (when p
      (setf (getf *conn* :proc) nil)
      (ignore-errors (close (sb-ext:process-input p)))
      (loop repeat 30
            while (ignore-errors (sb-ext:process-alive-p p))
            do (sleep 0.1))
      (when (ignore-errors (sb-ext:process-alive-p p))
        (ignore-errors (sb-ext:process-kill p 15))
        (loop repeat 20
              while (ignore-errors (sb-ext:process-alive-p p))
              do (sleep 0.1)))
      (ignore-errors (sb-ext:process-close p)))))

(defun kill-orphan-transports ()
  "Kill parentless (PPID 1) openssl s_client XMPP transports left behind by a
previous crash or bounce, before we spawn our own. Only PPID-1 children
match: our own live child has our pid, and the ps/awk pipeline's own argv
never is the transport command line itself."
  (let* ((ps "ps -ax -o pid=,ppid=,args= | awk '/openssl s_client/ && $2==1 {printf \"%s \", $1}'")
         (pids (string-trim " " (nth-value 0 (run-capture (list "/bin/sh" "-c" ps) 5)))))
    (when (plusp (length pids))
      (run-capture (list "/bin/sh" "-c" (concatenate 'string "kill " pids)) 5)
      (log-line "reaper: killed orphan transports: ~a" pids))))

(defun xmpp-stream-header ()
  (xmpp-send
   (format nil "<?xml version='1.0'?><stream:stream to='~a' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"
           (getf *conn* :host))))

(defun xmpp-connect ()
  (let* ((jid (cfg-str "bridge" "jid"))
         (host (subseq jid (1+ (position #\@ jid))))
         (password (trim (or (read-file-string (cfg-str "bridge" "password_file")) "")))
         (p (open-tunnel host 5222)))
    ;; NB: we WRITE to the child's stdin (process-input) and READ from its
    ;; stdout (process-output). Swapping these yields "descriptor N is not
    ;; a character output stream" at the first send (2026-09-27).
    (setf *conn* (list :proc p :host host :jid jid :password password
                       :in (sb-ext:process-output p)
                       :out (sb-ext:process-input p)
                       :buf ""))
    (xmpp-stream-header)
    (xmpp-authenticate)
    (xmpp-bind)
    (xmpp-send "<presence><priority>0</priority></presence>")
    (dolist (muc (cfg-list "bridge" "mucs"))
      (xmpp-join-muc muc))
    (setf *last-inbound* (now))
    (log-line "bridge online as ~a (CL bridge)" jid)))

(defun xmpp-send (&rest parts)
  "Write PARTS (strings) to the tunnel; one force-output per call."
  (let ((out (getf *conn* :out)))
    (dolist (s parts) (write-string s out))
    (force-output out)))

(defun xmpp-authenticate ()
  (let* ((jid (getf *conn* :jid))
         (user (subseq jid 0 (position #\@ jid)))
         (token (base64-encode
                 (format nil "~c~a~c~a" (code-char 0) user
                         (code-char 0) (getf *conn* :password)))))
    (xmpp-send
     (format nil "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>~a</auth>"
             token))
    (loop
      (let ((stanza (xmpp-next-stanza)))
        (cond ((null stanza) (error "xmpp: stream closed during auth"))
              ((xml-stanza-name-is stanza "success")
               (xmpp-stream-header)
               (return))
              ((xml-stanza-name-is stanza "failure")
               (error "xmpp auth failed: ~a"
                      (xml-inner-text stanza))))))))

(defun xmpp-bind ()
  (xmpp-send "<iq id='bind1' type='set'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>"
             (cfg-str "bridge" "resource" "autolith")
             "</resource></bind></iq>")
  (loop
    (let ((stanza (xmpp-next-stanza)))
      (cond ((null stanza) (error "xmpp: stream closed during bind"))
            ((and (xml-stanza-name-is stanza "iq")
                  (search "<bind" stanza))
             (let ((jid (xml-element-text stanza "jid")))
               (log-line "bound as ~a" jid))
             (return))))))

(defun xmpp-join-muc (room)
  (let ((nick (cfg-str "bridge" "muc_nick" "agent")))
    (xmpp-send
     (format nil "<presence to='~a/~a'><x xmlns='http://jabber.org/protocol/muc'><history maxstanzas='0'/></x></presence>"
             room nick))
    (log-line "joined MUC ~a (address me as '@~a ...')"
              room (cfg-str "bridge" "muc_trigger" nick))))

(defun xmpp-poll-nonblocking ()
  "Drain and dispatch whatever stanzas are already readable (used while
   a turn runs, so server pings get answered mid-turn)."
  (when *conn*
    (let ((in (getf *conn* :in)))
      (loop while (listen in)
            do (let ((ch (read-char in nil :eof)))
                 (when (eq ch :eof)
                     (error "xmpp stream closed"))
                 (setf *last-inbound* (now))
                 (setf (getf *conn* :buf)
                       (concatenate 'string (getf *conn* :buf) (string ch))))
            finally
              (loop
                (multiple-value-bind (el rest)
                    (extract-stanza (getf *conn* :buf))
                  (unless (and el (not (eq el :stream-close))) (return))
                  (setf (getf *conn* :buf) rest)
                  (dispatch-stanza el))
                (muc-rejoin-due))))))

(defun xmpp-next-stanza ()
  "One complete top-level stream element, as its raw string.
Returns nil on stream close. Blocks."
  (loop
    (multiple-value-bind (stanza rest)
        (extract-stanza (getf *conn* :buf))
      (when (eq stanza :stream-close)
        (return nil))
      (when stanza
        (setf (getf *conn* :buf) rest)
        (return stanza))
      (let ((ch (read-char (getf *conn* :in) nil :eof)))
        (when (eq ch :eof) (return nil))
        (setf *last-inbound* (now))
        (setf (getf *conn* :buf)
              (concatenate 'string (getf *conn* :buf) (string ch)))))))

(defun extract-stanza (buf)
  "Extract one complete top-level element from BUF.
Returns (values stanza-string rest), (values :stream-close rest), or
(values nil buf) when more bytes are needed. Quote-aware: '<' and '>'
inside attribute values do not affect depth."
  (labels ((starts-with (b i s) (and (<= (+ i (length s)) (length b))
                                     (string= b s :start1 i :end1 (+ i (length s))))))
    (let ((i 0))
      ;; skip leading whitespace
      (loop while (and (< i (length buf))
                       (member (char buf i) '(#\Space #\Tab #\Return #\Newline)))
            do (incf i))
      (cond ((>= i (length buf)) (values nil buf))
            ;; xml declaration / doctype
            ((or (starts-with buf i "<?") (starts-with buf i "<!"))
             (let ((gt (position #\> buf :start i)))
               (if gt (extract-stanza (subseq buf (1+ gt))) (values nil buf))))
            ;; stream open tag (never closes until disconnect): skip it
            ((starts-with buf i "<stream:stream")
             (let ((gt (position #\> buf :start i)))
               (if gt (extract-stanza (subseq buf (1+ gt))) (values nil buf))))
            ((starts-with buf i "</stream:stream") (values :stream-close ""))
            ((char= (char buf i) #\<)
             ;; scan one balanced element, tracking depth and quotes
             (let ((depth 0) (j i) (in-q nil) (q #\") (end nil)
                   (len (length buf)))
               (loop while (< j len)
                     do (let ((ch (char buf j)))
                          (cond (in-q (when (eql ch q) (setf in-q nil)))
                                ((or (eql ch #\") (eql ch #\'))
                                 (setf in-q t) (setf q ch))
                                ((eql ch #\<)
                                 (cond ((starts-with buf j "</") (decf depth) (incf j))
                                       ((starts-with buf j "<!--")
                                        (let ((e (search "-->" buf :start2 j)))
                                          (if e (setf j (+ e 2))
                                              (return-from extract-stanza (values nil buf)))))
                                       ((starts-with buf j "<?")
                                        (let ((e (search "?>" buf :start2 j)))
                                          (if e (setf j (+ e 1))
                                              (return-from extract-stanza (values nil buf)))))
                                       (t (incf depth))))
                                ((eql ch #\>)
                                 (when (and (>= j 1) (eql (char buf (1- j)) #\/))
                                   (decf depth))        ; self-closing tag
                                 (when (zerop depth)
                                   (setf end (1+ j))
                                   (return))))
                          (incf j)))
               (when end
                 (values (subseq buf i end) (subseq buf end)))))
            (t (values nil buf))))))

(defun xml-stanza-name (stanza)
  (let ((end (position-if (lambda (c) (member c '(#\Space #\Tab #\/ #\>))) stanza :start 1)))
    (subseq stanza 1 (or end 1))))

(defun xml-stanza-name-is (stanza name)
  (string= (xml-stanza-name stanza) name))

(defun xml-attr (stanza name)
  "Value of attribute NAME in the stanza's opening tag (string search)."
  (let* ((gt (position #\> stanza))
         (tag (and gt (subseq stanza 0 (1+ gt))))
         (key (concatenate 'string name "='")))
    (when tag
      (let ((pos (search key tag)))
        (when pos
          (let ((start (+ pos (length key))))
            (let ((end (position #\' tag :start start)))
              (when end (xml-unescape (subseq tag start end))))))))))

(defun xml-inner-text (stanza)
  "Text content of the stanza with all tags stripped."
  (xml-unescape
   (with-output-to-string (o)
     (let ((i 0) (n (length stanza)))
       (loop while (< i n)
             do (let ((ch (char stanza i)))
                  (if (eql ch #\<)
                      (let ((gt (position #\> stanza :start i)))
                        (setf i (if gt (1+ gt) n)))
                      (progn (write-char ch o) (incf i)))))))))

(defun xml-element-text (stanza tagname)
  "Text inside the first <tagname ...>...</tagname> child."
  (let* ((open (search (format nil "<~a" tagname) stanza))
         (text (when open
                 (let ((gt (position #\> stanza :start open)))
                   (when (and gt (not (eql (char stanza (1- gt)) #\/)))
                     (let ((close (search (format nil "</~a>" tagname) stanza :start2 gt)))
                       (when close (subseq stanza (1+ gt) close))))))))
    (when text (xml-unescape (xml-inner-text (format nil "<x>~a</x>" text))))))

(defun xmpp-send-state (to state)
  "XEP-0085 chat state to a 1:1 peer (:composing | :active | :paused).
   Only private chat: a room has no per-peer indicator. This replaces the
   old bridge's 5-minute 'still working' CHAT MESSAGE, which was noise —
   the indicator disappears on its own when the bridge dies, so a stuck
   turn looks stuck instead of generating spam."
  (let ((name (ecase state
                (:composing "composing")
                (:active "active")
                (:paused "paused"))))
    (log-line "typing -> ~a (~a)" to name)
    (xmpp-send (format nil "<message to='~a' type='chat'><~a xmlns='http://jabber.org/protocol/chatstates'/></message>"
                       (xml-escape to) name))))


(defun xmpp-send-message (to surface text)
  (let ((mtype (if (eq surface :xmpp-group) "groupchat" "chat"))
        (maxchars (cfg-int "autolith" "max_reply_chars" 8000)))
    (dolist (part (chunk-text (if (> (length text) maxchars)
                                  (cap-reply text)
                                  text)
                              1400))
      (xmpp-send (format nil "<message to='~a' type='~a'><body>~a</body></message>"
                         (xml-escape to) mtype (xml-escape part))))))


;;; ---------------------------------------------------------------------
;;; incoming stanza dispatch
;;; ---------------------------------------------------------------------

(defparameter *queue* '())   ; ((:peer ".." :surface .. :bodies ("..")))

(defun stanza-allowed-p (from)
  (let ((allow (cfg-list "bridge" "allow"))
        (dom (cfg-str "bridge" "allow_domain" "")))
    (or (member from allow :test #'string=)
        (and (plusp (length dom))
             (>= (length from) (1+ (length dom)))
             (string= from (format nil "@~a" dom)
                      :start1 (- (length from) (1+ (length dom))))))))

;;; ---------------------------------------------------------------------
;;; MUC self-heal
;;;
;;; The server never 409s a same-bare-JID rejoin: joining a room with our
;;; own nick silently transfers room occupancy (observed 2026-10-09, the
;;; armed canary's pre-say-lisp run displaced ops-test). say.lisp now
;;; joins under muc_nick-say, but kicks, affiliation changes, or a
;;; server-side purge can still strip a room while the stream stays up,
;;; and this bridge used to rejoin only at startup. So: watch our own
;;; MUC presence. Self unavailable (minus a 303 nick change) or a join
;;; error schedules a rejoin with per-room backoff; self-presence 110 on
;;; entry clears the pending heal.
;;; ---------------------------------------------------------------------

(defparameter *muc-rejoin* '()
  "Pending MUC heals: ((room attempts due-ut) ...). In-memory only; a
   stream reconnect rejoins every configured room anyway.")

(defun muc-status-codes (stanza)
  "All <status code='NNN'/> integers in a MUC presence stanza, in order."
  (let ((codes '()))
    (loop for i = 0 then (+ hit 7)
          for hit = (search "<status" stanza :start2 i)
          while hit
          do (let* ((gt (position #\> stanza :start hit))
                    (tag (and gt (subseq stanza hit gt)))
                    (k (and tag (search "code=" tag))))
               (when (and k (< (+ k 6) (length tag)))
                 (let* ((q (char tag (+ k 5)))
                        (start (+ k 6))
                        (end (position q tag :start start)))
                   (when end
                     (let ((n (parse-integer tag :start start
                                             :end end :junk-allowed t)))
                       (when n (push n codes))))))))
    (nreverse codes)))

(defun muc-heal-delay (attempts)
  "Backoff seconds before heal attempt N."
  (nth (min (1- attempts) 4) '(2 10 30 120 300)))

(defun muc-schedule-rejoin (room)
  (let* ((entry (assoc room *muc-rejoin* :test #'string=))
         (attempts (1+ (if entry (second entry) 0)))
         (delay (muc-heal-delay attempts)))
    (if entry
        (setf (second entry) attempts
              (third entry) (+ (now) delay))
        (push (list room attempts (+ (now) delay)) *muc-rejoin*))
    (log-line "MUC ~a: occupancy lost - rejoin in ~as (heal attempt ~d)"
              room delay attempts)))

(defun muc-clear-rejoin (room)
  "Drop a pending heal for ROOM. Returns t when one was pending."
  (let ((had (assoc room *muc-rejoin* :test #'string=)))
    (setf *muc-rejoin*
          (remove room *muc-rejoin* :key #'first :test #'string=))
    (and had t)))

(defun muc-rejoin-due ()
  "Fire pending MUC heals whose backoff has elapsed. Runs from the main
   loop and from xmpp-poll-nonblocking, so a loss mid-turn heals too."
  (dolist (entry *muc-rejoin*)
    (when (>= (now) (third entry))
      (let ((room (first entry)))
        (muc-clear-rejoin room)
        (log-line "MUC ~a: heal rejoin" room)
        (xmpp-join-muc room)))))

(defun dispatch-stanza (stanza)
  (cond
    ;; XEP-0199 ping
    ((and (xml-stanza-name-is stanza "iq")
          (search "type='get'" stanza)
          (search "<ping" stanza))
     (let ((id (or (xml-attr stanza "id") "0"))
           (from (xml-attr stanza "from")))
       (xmpp-send (format nil "<iq id='~a' type='result'~a/>"
                          (xml-escape id)
                          (if from (format nil " to='~a'" (xml-escape from)) "")))))
      ;; presence: our own MUC presence drives the self-heal (see
      ;; *muc-rejoin*); other occupants' join/leave/kick noise is ignored.
      ((xml-stanza-name-is stanza "presence")
       (let* ((from (or (xml-attr stanza "from") ""))
              (slash (position #\/ from))
              (room (and slash (subseq from 0 slash)))
              (nick (and slash (subseq from (1+ slash))))
              (type (xml-attr stanza "type")))
         (when (and room nick
                    (member room (cfg-list "bridge" "mucs") :test #'string=)
                    (string= nick (cfg-str "bridge" "muc_nick" "agent")))
           (let ((codes (muc-status-codes stanza)))
             (cond
               ;; our join settled: self-presence on entry clears any heal
               ((and (null type) (member 110 codes))
                (when (muc-clear-rejoin room)
                  (log-line "MUC ~a: occupancy confirmed (heal done)" room)))
               ;; nick change: still in the room, nothing to heal
               ((member 303 codes))
                 ;; removed for real (301 ban, 307 kick, 321/322 affiliation
                 ;; or membership, 332/333 shutdown) or join error: heal.
                 ;; Bare self-unavailable is occupancy-transfer noise (old
                 ;; session teardown after a restart, observed 06:03 on
                 ;; 10-09); scheduling on it would rejoin while already in.
                 ((or (equal type "error")
                      (and (equal type "unavailable")
                           (intersection codes '(301 307 321 322 332 333))))
                  (muc-schedule-rejoin room)))))))
    ;; messages
    ((xml-stanza-name-is stanza "message")
     (let* ((type (or (xml-attr stanza "type") "normal"))
            (body (xml-element-text stanza "body"))
            (from (or (xml-attr stanza "from") "")))
       (when (and body (plusp (length (trim body))))
         (cond ((string= type "groupchat")
                (let ((room (subseq from 0 (position #\/ from)))
                      (nick (and (position #\/ from)
                                 (subseq from (1+ (position #\/ from))))))
                  (when (and room nick
                             (member room (cfg-list "bridge" "mucs") :test #'string=)
                             (string/= nick (cfg-str "bridge" "muc_nick" "agent"))
                             ;; history replay on join carries a <delay>
                             (not (search "<delay" stanza)))
                    (handle-group-message room nick (trim body)))))
               ((member type '("chat" "normal") :test #'string=)
                (let ((bare (subseq from 0 (or (position #\/ from) (length from)))))
                    (if (stanza-allowed-p bare)
                        (if (command-p (trim body))
                            (handle-command bare (trim body))
                            (handle-dm bare (trim body)))
                      (log-line "IGNORED DM from ~a (not in allow list)" bare))))))))))

(defun handle-group-message (room nick body)
  (let ((trigger (cfg-str "bridge" "muc_trigger" "gregor")))
    ;; explicit @mention only
    (let ((pos (search (format nil "@~a" trigger) body :test #'char-equal)))
      (when pos
        (let* ((prompt (string-trim " ,;:"
                                    (remove-mention body trigger)))
               (prompt (if (plusp (length prompt)) prompt body)))
          (log-line "MUC ~a from ~a: ~a" room nick (subseq prompt 0 (min 200 (length prompt))))
          (enqueue room :xmpp-group prompt))))))


(defun remove-mention (body trigger)
  "Drop the '@trigger' mention from BODY."
  (let ((needle (format nil "@~a" trigger)))
    (multiple-value-bind (hit len)
        (loop for i below (- (length body) (length needle))
              when (string-equal body needle :start1 i :end1 (+ i (length needle)))
                return (values i (length needle)))
      (if hit
          (concatenate 'string (subseq body 0 hit) (subseq body (+ hit len)))
          body))))

(defun handle-dm (bare body)
  (log-line "DM from ~a: ~a" bare (subseq body 0 (min 200 (length body))))
  ;; immediate feedback: "is typing..." the moment the DM lands
  (ignore-errors (xmpp-send-state bare :composing))
  ;; a DM arriving mid-turn waits silently until the turn ends; say so
  (when *turn*
    (let ((waited (- (now) (or (getf *turn* :started) (now)))))
      (when (> waited 10)
        (deliver-notice bare :xmpp-private
                        (format nil "queued - I'll read this when the current job finishes (~as so far)" waited)))))
  (enqueue bare :xmpp-private body))

(defun queue-sync ()
  "Mirror *queue* into *state* and persist. A message queued here survives a
bounce: main restores it on start and it runs, instead of dying with the
in-memory-only queue (lost DM observed 2026-10-09 ~06:50)."
  (setf (getf *state* :queue) *queue*)
  (save-state))

(defun enqueue (peer surface body)
  (let ((item (find peer *queue* :key (lambda (q) (getf q :peer))
                    :test #'string=)))
    (if item
        (push body (getf item :bodies))
        (push (list :peer peer :surface surface :bodies (list body))
              *queue*))
    (queue-sync)))

(defun queue-flatten (item)
  "Oldest body first."
  (nreverse (getf item :bodies)))

(defun xmpp-next-stanza-with-timeout ()
  "One complete stanza, or nil when nothing is fully available yet.
NEVER blocks: tops up the buffer with whatever bytes are readable right
now, then tries to extract one stanza. A stanza that stalls mid-stream
stays buffered for the next pass instead of freezing the loop.
(2026-10-05: this used to hand off to the BLOCKING xmpp-next-stanza
whenever any byte was readable, so a partial stanza blocked read-char
forever and froze the entire main loop — keepalive, pp-poll, task
announce, no reconnect — for 20 hours. EOF and :stream-close now raise
instead of returning nil, which would have spun silently forever.)"
  (let ((in (getf *conn* :in))
        (got 0))
    ;; top up the buffer with whatever is readable right now
    (loop while (listen in)
          do (let ((ch (read-char in nil :eof)))
               (when (eq ch :eof) (error "xmpp stream closed"))
               (incf got)
               (setf *last-inbound* (now))
               (setf (getf *conn* :buf)
                     (concatenate 'string (getf *conn* :buf) (string ch)))))
    ;; extract at most one complete stanza from the buffer
    (multiple-value-bind (stanza rest)
        (extract-stanza (getf *conn* :buf))
      ;; the split into modules dropped this guard (and the :eof one above),
      ;; so :stream-close came back as if it were a stanza and the caller died
      ;; with ":STREAM-CLOSE is not of type SEQUENCE" on every rejoin.
      (when (eq stanza :stream-close) (error "xmpp stream closed"))
      (if stanza
          (progn (setf (getf *conn* :buf) rest) stanza)
          ;; idle: keep the ~0.5s loop granularity; mid-stanza: brief
          ;; pause so a streaming stanza completes without hot-spinning
          ;; the extract scan
          (progn (sleep (if (plusp got) 0.05 0.5)) nil)))))

;;; ---------------------------------------------------------------------
;;; detached child-agent completions
;;;
;;; The agent can hand long work to a child (task.run). A DETACHED child
;;; finishes out of band: the standing conversation does not change until
;;; the parent's next turn boundary, so the result would sit until the
;;; owner happened to write again. Watch the task store and push it.
;;;
;;; Store: <data>/tasks/<conversation>/<child>/result.sexp, one plist:
;;; :agent-definition :id :name :agent :agent-source :assignment :status
;;; :output :error :yielded-p :request-count :usage :duration-ms :model
;;; :detached. Text fields may arrive as #A((n) BASE-CHAR ...) vectors, so
;;; everything goes through text-of. :status and :duration-ms sit after
;;; :output, so a half-written file fails the completeness check instead of
;;; announcing a truncated result.
;;; ---------------------------------------------------------------------



;;; ---------------------------------------------------------------------
;;; the surfaces this module owns
;;; ---------------------------------------------------------------------

(register-surface :xmpp-private
                  :sender (lambda (peer text)
                            ;; clear the typing indicator just before the body lands
                            (ignore-errors (xmpp-send-state peer :active))
                            (xmpp-send-message peer :xmpp-private text))
                  :typing #'xmpp-send-state
                  :policy (cfg-str "bridge" "reply_policy_private")
                  :label "PRIVATE CHAT MESSAGE"
                  :private-p t)

(register-surface :xmpp-group
                  :sender (lambda (peer text) (xmpp-send-message peer :xmpp-group text))
                  :policy (cfg-str "bridge" "reply_policy_group")
                  :label "GROUP CHAT MESSAGE")

;;; ---------------------------------------------------------------------
;;; adapter tick and status
;;; ---------------------------------------------------------------------

(register-poller (lambda ()
                   (xmpp-poll-nonblocking)
                   (muc-rejoin-due)))

(register-status
 (lambda ()
   (if *xmpp-on*
       (format nil "xmpp queue ~d, last inbound ~as ago"
               (length *queue*)
               (max 0 (- (now) *last-inbound*)))
       "xmpp off")))
