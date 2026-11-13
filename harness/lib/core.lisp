;;;; core.lisp -- the foundation every other module stands on: paths, the

;;;; TOML config reader, logging, subprocess capture, JSON, base64, and the
;;;; durable state file that holds watermarks and parked texts.
;;;; 
;;;; No transport and no agent knowledge lives here.

(defpackage :SG.CORE
  (:use :CL)
  (:export
   #:*HOME*
   #:DIR-OF
   #:*HARNESS-DIR*
   #:*CONFIG-PATH*
   #:HOME-PATH
   #:*STATE-PATH*
   #:*TURN-MARK-PATH*
   #:*NO-TEXT-MARK-PATH*
   #:MARK-NO-TEXT-TURN
   #:SPLIT-SEQ
   #:TOML-STRIP-COMMENT
   #:TOML-UNQUOTE
   #:TOML-VALUE
   #:TOML-PARSE
   #:*CONFIG*
   #:CFG-STR
   #:CFG-INT
   #:CFG-LIST
   #:*LOG-PATH*
   #:LOG-LINE
   #:TIMESTAMP-STRING
   #:NOW
   #:TRIM
   #:SLURP-EXACT
   #:SLURP-LINES
   #:RUN-CAPTURE
   #:FILE-SIZE
   #:READ-FILE-STRING
   #:JSON-PARSE
   #:JGET
   #:JSON-ESCAPE
   #:*BASE64-ALPHABET*
   #:BASE64-ENCODE
   #:*STATE*
   #:LOAD-STATE
   #:SAVE-STATE
   #:WATERMARK-FOR
   #:BUMP-WATERMARK
   #:TURN-BEGIN
   #:TURN-END
   #:TURN-MARK-AGE
   #:CFG-BOOL*
   #:*TRANSPORTS*
   #:TRANSPORT-ON-P   #:GETENV*
   #:CURL-BIN
   #:*STATE-LOCK*
   #:WITH-STATE-LOCK
))
(in-package :SG.CORE)

;;; ---------------------------------------------------------------------
;;; config (minimal TOML subset: [section], "strings", ints, bools, [arrays])
;;; ---------------------------------------------------------------------

(defun getenv* (name)
  #+sbcl (sb-posix:getenv name))

(defparameter *home* (getenv* "HOME"))

(defun dir-of (path)
  (let ((p (namestring (truename path))))
    (subseq p 0 (1+ (position #\/ p :from-end t)))))

(defun parent-dir (path)
  "Directory above the one holding PATH."
  (let* ((dir (dir-of path))
         (trimmed (string-right-trim "/" dir)))
    (subseq trimmed 0 (1+ (position #\/ trimmed :from-end t)))))

;; The bridge is loaded as source from harness/lib/, so *LOAD-TRUENAME* always
;; names a file in lib/ and harness/ is one level up. A compiled-from-cache load
;; would break this, which is why the modules are loaded as source.
(defparameter *harness-dir*
  (or (let ((cfg (getenv* "BRIDGE_CONFIG")))
        (when (and cfg (probe-file cfg)) (dir-of cfg)))
      (ignore-errors (parent-dir *load-truename*))
      (concatenate 'string *home* "/saguaro-live/harness/")))

(defparameter *config-path*
  (or (getenv* "BRIDGE_CONFIG")
      (merge-pathnames "config.toml" *harness-dir*)))

(defun home-path (relative)
  "HOME-relative path built by string concatenation.

   merge-pathnames is wrong here: HOME has no trailing slash, so it is
   treated as a FILE name and '.cache/x' becomes /home/.cache/x/al on a
   /home/al box. That silently broke the state file and the watchdog's
   turn-in-flight marker on cutover (2026-09-27)."
  (format nil "~a/~a" *home* relative))

(defparameter *state-path*
  (or (getenv* "SAGUARO_STATE")
      (home-path ".cache/saguaro-bridge-state.sexp")))

(defparameter *turn-mark-path* (home-path ".cache/saguaro-turn-active"))

;; A turn that produced NO assistant text. Autolith aborts such a turn on
;; PROVIDER-PROTOCOL-ERROR "Compaction produced no summary text." (a failed
;; mid-turn compaction) BEFORE writing any record, so there is nothing to
;; deliver and the failure is invisible to the watchdog. Overwritten on each
;; such turn; watchdog.py keeps its own alerted-watermark and pages the owner.
(defparameter *no-text-mark-path* (home-path ".cache/saguaro-no-text-turn"))

(defun mark-no-text-turn (all new &optional conversation)
  (ignore-errors
    (with-open-file (f *no-text-mark-path* :direction :output
                       :if-exists :supersede :if-does-not-exist :create)
      (format f "~a no-text turn: ~d new records, ~d ours, conv ~a~%"
              (timestamp-string) (length all) (length new)
                (or conversation "?")))))

(defun split-seq (s sep)
  (loop for start = 0 then (1+ end)
        for end = (position sep s :start start)
        collect (subseq s start (or end (length s)))
        while end))

(defun toml-strip-comment (line)
  "Drop a trailing # comment, respecting double-quoted strings."
  (let ((in-str nil))
    (loop for i below (length line)
          for ch = (char line i)
          do (cond ((eql ch #\")
                    (setf in-str (not in-str)))
                   ((and (eql ch #\#) (not in-str))
                    (return (string-trim " " (subseq line 0 i)))))
          finally (return (string-trim " " line)))))

(defun toml-unquote (s)
  (with-output-to-string (o)
    (loop for i below (length s)
          for ch = (char s i)
          do (cond ((and (eql ch #\\) (< (1+ i) (length s)))
                    (incf i)
                    (case (char s i)
                      (#\n (write-char #\Newline o))
                      (#\t (write-char #\Tab o))
                      (#\r (write-char #\Return o))
                      (#\" (write-char #\" o))
                      (#\\ (write-char #\\ o))
                      (t (write-char (char s i) o))))
                   (t (write-char ch o))))))

(defun toml-value (raw)
  (cond ((and (> (length raw) 1)
              (eql (char raw 0) #\") (eql (char raw (1- (length raw))) #\"))
         (toml-unquote (subseq raw 1 (1- (length raw)))))
        ((and (> (length raw) 1)
              (eql (char raw 0) #\[) (eql (char raw (1- (length raw))) #\]))
         (let ((inner (string-trim " " (subseq raw 1 (1- (length raw))))))
           (if (plusp (length inner))
               (loop for part in (split-seq inner #\,)
                     when (plusp (length (string-trim " " part)))
                       collect (toml-value (string-trim " " part)))
               nil)))
        ((string= raw "true") :true)
        ((string= raw "false") :false)
        (t (handler-case (parse-integer raw) (error () raw)))))

(defun toml-parse (path)
  (with-open-file (f path :if-does-not-exist :error)
    (let ((table (make-hash-table :test 'equal))
          (section ""))
      (loop for raw-line = (read-line f nil nil)
            while raw-line
            do (let ((line (toml-strip-comment raw-line)))
                 (when (plusp (length line))
                   (cond ((and (eql (char line 0) #\[)
                               (eql (char line (1- (length line))) #\]))
                          (setf section (string-trim "[]" line)))
                         (t
                          (let ((eq (position #\= line)))
                            (when eq
                              (let* ((key (string-trim " " (subseq line 0 eq)))
                                     (val (toml-value (string-trim " " (subseq line (1+ eq))))))
                                (let ((sec (gethash section table)))
                                  (unless sec
                                    (setf sec (make-hash-table :test 'equal)
                                          (gethash section table) sec))
                                  (setf (gethash key sec) val))))))))))
      table)))

(defparameter *config* (toml-parse *config-path*))

(defun cfg-str (section key &optional default)
  (let ((sec (gethash section *config*)))
    (if sec
        (let ((v (gethash key sec)))
          (cond ((stringp v) v)
                ((null v) default)
                ((eq v :false) default)
                (t (format nil "~a" v))))
        default)))

(defun cfg-int (section key &optional default)
  (let ((sec (gethash section *config*)))
    (if sec
        (let ((v (gethash key sec)))
          (if (integerp v) v default))
        default)))

(defun cfg-list (section key)
  (let ((sec (gethash section *config*)))
    (if sec
        (let ((v (gethash key sec)))
          (if (listp v) v nil))
        nil)))

;;; ---------------------------------------------------------------------
;;; small utils
;;; ---------------------------------------------------------------------

(defparameter *log-path* (merge-pathnames "bridge.log" *harness-dir*))

(defun log-line (fmt &rest args)
  (let ((line (format nil "~a ~a~%"
                      (timestamp-string) (apply #'format nil fmt args))))
    (write-string line)
    (force-output)
    (with-open-file (f *log-path* :direction :output
                       :if-exists :append :if-does-not-exist :create)
      (write-string line f))))

(defun timestamp-string ()
  (multiple-value-bind (s m h) (decode-universal-time (get-universal-time) 0)
    (format nil "~2,'0d:~2,'0d:~2,'0d" h m s)))

(defun now () (get-universal-time))

(defun trim (s) (string-trim '(#\Space #\Tab #\Return #\Newline) s))

(defun slurp-exact (stream)
  "Read to EOF preserving bytes exactly (read-line/write-line would add a
   newline to an unterminated last line and desync incremental offsets)."
  (with-output-to-string (o)
    (loop for ch = (read-char stream nil nil)
          while ch
          do (write-char ch o))))

(defun slurp-lines (stream)
  (with-output-to-string (o)
    (loop for line = (read-line stream nil nil)
          while line
          do (write-line line o))))

(defun run-capture (argv &optional timeout-secs)
  "Run argv, drain stdout and stderr, reap. Returns (values out err code).
OpenBSD SBCL rejects run-program :output :string, hence pipes (glochid)."
  (let ((p (ignore-errors
            (sb-ext:run-program (first argv) (rest argv)
                                :output :stream :error :stream
                                :wait nil :search t))))
    (unless p (return-from run-capture (values "" "spawn failed" 127)))
    (unwind-protect
         (let ((out (slurp-lines (sb-ext:process-output p)))
               (err (slurp-lines (sb-ext:process-error p))))
           (if timeout-secs
               (loop repeat (max 1 (floor (* 10 timeout-secs)))
                     while (sb-ext:process-alive-p p)
                     do (sleep 0.1))
               (sb-ext:process-wait p))
           (when (sb-ext:process-alive-p p)
             (ignore-errors (sb-ext:process-kill p 9)))
           (values out err (sb-ext:process-exit-code p)))
      (ignore-errors (close (sb-ext:process-output p)))
      (ignore-errors (close (sb-ext:process-error p)))
      (ignore-errors (sb-ext:process-close p)))))

(defun file-size (path)
  (ignore-errors (with-open-file (f path) (file-length f))))

(defun read-file-string (path)
  (ignore-errors
    (with-open-file (f path :if-does-not-exist nil)
      (when f (slurp-lines f)))))

;;; ---------------------------------------------------------------------
;;; JSON (glochid's parser): objects -> alists, arrays -> lists,
;;; true/false/null -> :true/:false/:null
;;; ---------------------------------------------------------------------

(defun curl-bin ()
  "curl path: [bridge] curl, then [pp] curl, else the first that exists
(OpenBSD builds put it in /usr/local/bin, Linux in /usr/bin)."
  (or (cfg-str "bridge" "curl")
      (cfg-str "pp" "curl")
      (find-if #'probe-file '("/usr/local/bin/curl" "/usr/bin/curl"))
      "/usr/local/bin/curl"))

(defun json-parse (text)
  (let ((i 0) (n (length text)))
    (labels ((peek () (when (< i n) (char text i)))
             (skip-ws ()
               (loop while (and (< i n)
                                (member (char text i)
                                        '(#\Space #\Newline #\Tab #\Return)))
                     do (incf i)))
             (advance () (incf i))
             (parse-string ()
               (advance)
               (with-output-to-string (o)
                 (loop
                   (let ((c (peek)))
                     (cond ((null c) (error "json: unterminated string"))
                           ((eql c #\") (advance) (return))
                           ((eql c #\\)
                            (advance)
                            (let ((e (peek)))
                              (case e
                                (#\" (write-char #\" o) (advance))
                                (#\\ (write-char #\\ o) (advance))
                                (#\/ (write-char #\/ o) (advance))
                                (#\b (write-char #\Backspace o) (advance))
                                (#\f (write-char #\Page o) (advance))
                                (#\n (write-char #\Newline o) (advance))
                                (#\r (write-char #\Return o) (advance))
                                (#\t (write-char #\Tab o) (advance))
                                (#\u (advance)
                                     (write-char (code-char (parse-hex 4)) o))
                                (t (error "json: bad escape ~s" e)))))
                           (t (write-char c o) (advance)))))))
             (parse-hex (count)
               (let ((v 0))
                 (dotimes (k count v)
                   (let ((c (peek)))
                     (unless (and c (digit-char-p c 16))
                       (error "json: bad \\u escape"))
                     (setf v (+ (* v 16) (digit-char-p c 16)))
                     (advance)))))
             (parse-number ()
               (let ((start i))
                 (when (eql (peek) #\-) (advance))
                 (loop while (and (< i n)
                                  (find (char text i) "0123456789.eE+"))
                       do (advance))
                 (let ((s (subseq text start i)))
                   (if (find #\. s) (read-from-string s)
                       (parse-integer s)))))
             (parse-object ()
               (advance)
               (let ((acc '()))
                 (skip-ws)
                 (when (eql (peek) #\}) (advance) (return-from parse-object acc))
                 (loop
                   (skip-ws)
                   (unless (eql (peek) #\") (error "json: want key string"))
                   (let* ((k (parse-string))
                          (v (progn (skip-ws)
                                    (unless (eql (peek) #\:)
                                      (error "json: want :"))
                                    (advance)
                                    (parse-value))))
                     (push (cons k v) acc))
                   (skip-ws)
                   (cond ((eql (peek) #\,) (advance))
                         ((eql (peek) #\}) (advance)
                          (return-from parse-object (nreverse acc)))
                         (t (error "json: want , or }"))))))
             (parse-array ()
               (advance)
               (let ((acc '()))
                 (skip-ws)
                 (when (eql (peek) #\]) (advance)
                   (return-from parse-array acc))
                 (loop
                   (push (parse-value) acc)
                   (skip-ws)
                   (cond ((eql (peek) #\,) (advance))
                         ((eql (peek) #\]) (advance)
                          (return-from parse-array (nreverse acc)))
                         (t (error "json: want , or ]"))))))
             (parse-value ()
               (skip-ws)
               (let ((c (peek)))
                 (cond ((null c) (error "json: unexpected end"))
                       ((eql c #\{) (parse-object))
                       ((eql c #\[) (parse-array))
                       ((eql c #\") (parse-string))
                       ((eql c #\t) (expect-lit "true") :true)
                       ((eql c #\f) (expect-lit "false") :false)
                       ((eql c #\n) (expect-lit "null") :null)
                       (t (parse-number)))))
             (expect-lit (lit)
               (unless (and (<= (+ i (length lit)) n)
                            (string= text lit :start1 i :end1 (+ i (length lit))))
                 (error "json: bad literal at ~d" i))
               (incf i (length lit))))
      (prog1 (parse-value) (skip-ws)))))

(defun jget (obj key)
  (let ((v (assoc key obj :test #'string=)))
    (when v (cdr v))))

(defun json-escape (s)
  (with-output-to-string (o)
    (loop for ch across s
          do (cond ((eql ch #\") (write-string "\\\"" o))
                   ((eql ch #\\) (write-string "\\\\" o))
                   ((eql ch #\Newline) (write-string "\\n" o))
                   ((eql ch #\Return) (write-string "\\r" o))
                   ((eql ch #\Tab) (write-string "\\t" o))
                   ((< (char-code ch) 32)
                    (format o "\\u~4,'0x" (char-code ch)))
                   (t (write-char ch o))))))

(defparameter *base64-alphabet*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode (s)
  (let* ((bytes (map 'list #'char-code s))
         (n (length bytes))
         (out (make-string-output-stream)))
    (labels ((enc (v) (write-char (char *base64-alphabet* v) out))
             (pad () (write-char #\= out))
             (grp (i)
               (let* ((b1 (if (< i n) (nth i bytes) 0))
                      (b2 (if (< (1+ i) n) (nth (1+ i) bytes) 0))
                      (b3 (if (< (+ i 2) n) (nth (+ i 2) bytes) 0)))
                 (enc (ash b1 -2))
                 (enc (logior (ash (logand b1 3) 4) (ash b2 -4)))
                 (if (< (1+ i) n)
                     (enc (logior (ash (logand b2 15) 2) (ash b3 -6)))
                     (pad))
                 (if (< (+ i 2) n)
                     (enc (logand b3 63))
                     (pad)))))
      (loop for i below n by 3 do (grp i)))
    (get-output-stream-string out)))

;;; ---------------------------------------------------------------------
;;; durable state — watermarks + parked (undelivered) texts
;;;;
;;; (:version 1
;;;  :watermarks ((".../0001.sexp" . 6300) ...)
;;;  :parked ((:peer ".." :surface pp-dm :texts (".." ...)) ...))
;;;  :queue   ((:peer ".." :surface .. :bodies (".." ...)) ...))
;;; ---------------------------------------------------------------------

(defparameter *state*
  (list :version 1 :watermarks '() :parked '() :queue '()))

(defparameter *state-lock* (sb-thread:make-mutex :name "saguaro-state")
  "Serializes *STATE* across channel worker threads. Recursive: the mutators
take it and then call SAVE-STATE, which takes it again.")

(defmacro with-state-lock (&body body)
  `(sb-thread:with-recursive-lock (*state-lock*) ,@body))

(defun load-state ()
  (with-state-lock
    (let ((raw (read-file-string *state-path*)))
      (when raw
        (handler-case
            (let ((form (with-input-from-string (s raw)
                          (let ((*package* (find-package :keyword))
                                (*read-eval* nil))
                            (read s)))))
              (when (and (listp form) (eq (getf form :version) 1))
                (setf *state* form)))
          (error (e) (format t "state: unreadable, starting fresh: ~a~%" e))))
      (unless (getf *state* :version)
        (setf *state* (list :version 1 :watermarks '() :parked '() :queue '()))))))

(defun save-state ()
  "Persist watermarks + parked deliveries. A failure here means replies can
   be lost on restart, so it is reported, not swallowed."
  (with-state-lock
    (handler-case
        (progn
          (ensure-directories-exist *state-path*)
          (with-open-file (f *state-path* :direction :output
                             :if-exists :supersede :if-does-not-exist :create)
            (let ((*package* (find-package :keyword)))
              (prin1 *state* f))
            (terpri f)))
      (error (e) (log-line "STATE SAVE FAILED (~a): ~a" *state-path* e)))))

(defun watermark-for (path)
  (or (cdr (assoc (namestring path) (getf *state* :watermarks)
                  :test #'string=))
      0))

(defun bump-watermark (path seq)
  (let* ((key (namestring path))
         (cur (watermark-for path)))
    (when (> seq cur)
      (setf (getf *state* :watermarks)
            (acons key seq
                   (remove key (getf *state* :watermarks)
                           :key #'car :test #'string=)))
      t)))

;;; ---------------------------------------------------------------------
;;; turn-in-flight marker (same file watchdog.py reads)
;;; ---------------------------------------------------------------------

(defun turn-begin ()
  "Marker the watchdog reads to defer repairs mid-turn. Report failure:
   without it a watchdog restart can eat the answer."
  (handler-case
      (progn
        (ensure-directories-exist *turn-mark-path*)
        (with-open-file (f *turn-mark-path* :direction :output
                           :if-exists :supersede)
          (prin1 (now) f)))
    (error (e) (log-line "TURN MARKER WRITE FAILED (~a): ~a" *turn-mark-path* e))))

(defun turn-end ()
  (ignore-errors (delete-file *turn-mark-path*)))

(defun turn-mark-age ()
  (let ((raw (read-file-string *turn-mark-path*)))
    (and raw
         (ignore-errors (- (now) (parse-integer (trim raw)))))))

;;; ---------------------------------------------------------------------
;;; pricklypear eval client (curl + bearer token, glochid pattern)
;;; ---------------------------------------------------------------------

(defun cfg-bool* (section key)
  (let ((sec (gethash section *config*)))
    (and sec (eq (gethash key sec) :true))))

;;; Which surfaces this bridge serves: "pp" (habitat DM, the default) and/or
;;; "xmpp". XMPP is OPT-IN: it carries a JID, an openssl TLS tunnel, room
;;; joins and an inbound-liveness watchdog, and none of that should be able
;;; to take the habitat surface down. A surface listed here still needs its
;;; own switch to actually run ([pp] enabled/base, [bridge] jid/mucs).
;;;
;;; Before this existed, xmpp_connect sat in front of the whole main loop,
;;; so a dead or unconfigured XMPP stream meant pp-dm was never polled at
;;; all -- the transport ranking was an accident of loop nesting.
(defparameter *transports*
  (let ((v (cfg-list "bridge" "transports")))
    (if v
        (mapcar (lambda (s) (string-downcase (trim s))) v)
        (list "pp"))))

(defun transport-on-p (name)
  (and (member name *transports* :test #'string=) t))

