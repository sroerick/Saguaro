;;;; bridge.lisp — xmpp + pricklypear-dm gateway for the standing autolith
;;;; session. Common Lisp rewrite of bridge.py (2026-09-27).
;;;;
;;;; Zero-dependency sbcl --script, same house pattern as glochid.lisp:
;;;;   - no quicklisp; SBCL contribs + subprocesses only
;;;;   - TLS via /usr/bin/openssl s_client -starttls xmpp (SBCL has no TLS;
;;;;     the child process is a byte pipe in both directions)
;;;;   - HTTP via /usr/local/bin/curl (glochid's pp-raw pattern)
;;;;
;;;; Why a rewrite (the silent-turn failure modes of bridge.py):
;;;;
;;;;   1. TIME-BASED WAIT. Python waited turn_timeout_secs (900s) and gave
;;;;      up; gregor's real turns run 30-60+ min, so the final answer landed
;;;;      in the conversation log with nobody polling. The next turn took a
;;;;      fresh watermark and the orphaned answer was consumed, undelivered,
;;;;      forever ("How did it go" x3 in bridge.log). Here: wait on PROGRESS
;;;;      (turn active or log growing); give up only after a short settle
;;;;      quiet, under a generous hard cap.
;;;;
;;;;   2. VOLATILE WATERMARK. Python kept watermarks in memory; any restart
;;;;      reset them mid-turn. Here: per-chunk-file watermarks + undelivered
;;;;      texts persist in a state file; a restart re-delivers instead of
;;;;      consuming.
;;;;
;;;;   3. SWALLOWED DELIVERY ERRORS. Python's pp_say failure path sent the
;;;;      error through the same broken pipe inside (except: pass). Here:
;;;;      delivery retries with backoff; anything undelivered parks in the
;;;;      state file until it lands.
;;;;
;;;; External contracts kept from bridge.py (watchdog.py / canary.py /
;;;; start-sessions.sh keep working):
;;;;   - tmux session "xmpp-bridge"; log at harness/bridge.log
;;;;   - turn-in-flight marker  ~/.cache/saguaro-turn-active
;;;;   - config in harness/config.toml ([bridge] [autolith] [pp])
;;;;
;;;; Run:  sbcl --script bridge.lisp

(in-package :cl-user)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute)
         (require :sb-posix))

;; The conversation logs contain #A((n) BASE-CHAR . "...") arrays; the
;; reader must see the real CL:BASE-CHAR, so records are read in a
;; scratch package that uses CL (not KEYWORD, where :BASE-CHAR would be
;; an invalid element type). Keywords still read as keywords.
(defpackage :bridge-sexp-read (:use :cl))

;; `sbcl --script` compiles each top-level form in order, so forward
;; references between forms emit harmless "undefined variable/function"
;; warnings. Muffle compile-time noise; runtime errors still surface.
#+sbcl (declaim (sb-ext:muffle-conditions warning sb-ext:compiler-note))

;;; ---------------------------------------------------------------------
;;; config (minimal TOML subset: [section], "strings", ints, bools, [arrays])
;;; ---------------------------------------------------------------------

(defun getenv* (name)
  #+sbcl (sb-posix:getenv name))

(defparameter *home* (getenv* "HOME"))

(defun dir-of (path)
  (let ((p (namestring (truename path))))
    (subseq p 0 (1+ (position #\/ p :from-end t)))))

(defparameter *harness-dir*
  (or (let ((cfg (getenv* "BRIDGE_CONFIG")))
        (when (and cfg (probe-file cfg)) (dir-of cfg)))
      (ignore-errors (dir-of *load-truename*))
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
;;; ---------------------------------------------------------------------

(defparameter *state*
  (list :version 1 :watermarks '() :parked '()))

(defun load-state ()
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
      (setf *state* (list :version 1 :watermarks '() :parked '())))))

(defun save-state ()
  "Persist watermarks + parked deliveries. A failure here means replies can
   be lost on restart, so it is reported, not swallowed."
  (handler-case
      (progn
        (ensure-directories-exist *state-path*)
        (with-open-file (f *state-path* :direction :output
                           :if-exists :supersede :if-does-not-exist :create)
          (let ((*package* (find-package :keyword)))
            (prin1 *state* f))
          (terpri f)))
    (error (e) (log-line "STATE SAVE FAILED (~a): ~a" *state-path* e))))

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

(defparameter *pp-on* (and (cfg-bool* "pp" "enabled") (cfg-str "pp" "base")))

(defparameter *pp-base* (cfg-str "pp" "base"))
(defparameter *pp-token-file* (cfg-str "pp" "token_file"))
(defparameter *pp-user* (cfg-str "pp" "user" ""))
(defparameter *pp-auth* (cfg-str "pp" "auth" "bearer"))
(defparameter *pp-poll-secs* (cfg-int "pp" "poll_secs" 6))
(defparameter *pp-poll-timeout* (cfg-int "pp" "poll_timeout" 60))
(defparameter *pp-chunk-chars* (cfg-int "pp" "chunk_chars" 3500))
(defparameter *pp-allow* (cfg-list "pp" "allow"))
(defparameter *pp-inbox-lib* (cfg-str "pp" "inbox_lib"))

(defun pp-token ()
  (or (and *pp-token-file* (trim (or (read-file-string *pp-token-file*) "")))
      (getenv* "PP_TOKEN")
      ""))

(defparameter *pp-body-tmp* "/tmp/saguaro-pp-body.json")

(defun curl-bin ()
  "curl path: [pp] curl config, else the first that exists (OpenBSD builds
put it in /usr/local/bin, Linux in /usr/bin)."
  (or (cfg-str "pp" "curl")
      (find-if #'probe-file '("/usr/local/bin/curl" "/usr/bin/curl"))
      "/usr/local/bin/curl"))

(defun pp-raw (expr timeout)
  (with-open-file (f *pp-body-tmp* :direction :output :if-exists :supersede)
    (format f "{\"expr\":\"~a\"}" (json-escape expr)))
  (let ((auth (if (string= *pp-auth* "basic")
                  (format nil "Authorization: Basic ~a"
                          (base64-encode (format nil "~a:~a" *pp-user* (pp-token))))
                  (format nil "Authorization: Bearer ~a" (pp-token)))))
    (run-capture
     (list (curl-bin) "-s" "-m" (write-to-string timeout)
           "-H" auth "-H" "Content-Type: application/json"
           "-d" (format nil "@~a" *pp-body-tmp*)
           (format nil "~a/api/eval" *pp-base*))
     (+ timeout 5))))

(defun pp-eval (expr &optional (timeout *pp-poll-timeout*))
  (multiple-value-bind (out code) (pp-raw expr timeout)
    (if (and out (plusp (length out)))
        (let ((r (json-parse out)))
          (if (eq (jget r "ok") :true)
              (or (jget r "value") "")
              (error "pp eval error: ~a" (jget r "error"))))
        (error "curl exit ~d, empty response" code))))

;;; chat + inbox libs, mirroring bridge.py's pp_load_libs. A deploy or
;;; image restart resets loaded libs; the poller detects "unbound" errors
;;; and calls this again.

(defun pp-load-libs ()
  (pp-eval "(load-library \"chat\")")
  (ignore-errors (pp-eval "(load-library \"ntfy\")"))
  (unless (ignore-errors (pp-eval "(load-library \"inbox\")"))
    (let ((src (and *pp-inbox-lib* (read-file-string *pp-inbox-lib*))))
      (when src
        (let ((stripped (with-output-to-string (o)
                          (dolist (line (split-seq src #\Newline))
                            (let ((tl (string-trim " " line)))
                              (unless (and (> (length tl) 6)
                                           (string= tl "(route " :end1 7))
                                (write-line line o)))))))
          (pp-eval (format nil "(load-string ~s)" stripped)))))))

(defun pp-lisp-str (s) (format nil "~s" s))

(defun pp-say-once (peer text)
  "Post to a DM thread as the agent identity, chunked, then one inbox row."
  (dolist (part (chunk-text text *pp-chunk-chars*))
    (pp-eval (format nil "(chat/say-dm ~a ~a)"
                     (pp-lisp-str peer) (pp-lisp-str part))))
  (ignore-errors
   (pp-eval (format nil "(inbox/add ~a \"dm\" ~a)"
                    (pp-lisp-str "gregor") (pp-lisp-str text)))))

(defun pp-say-with-retry (peer text &optional (attempts 4))
  "Retry with backoff. Returns t on success; on final failure the caller
parks the text so it is retried later, never dropped."
  (loop for attempt below attempts
        do (handler-case
               (progn (pp-say-once peer text) (return t))
             (error (e)
               (log-line "pp say attempt ~d to ~a failed: ~a"
                         (1+ attempt) peer e)
               (unless (= attempt (1- attempts))
                 (sleep (* 5 (1+ attempt))))))))

;;; the same poll expression bridge.py used (chat lib, all DM rooms)
(defparameter *pp-poll-expr*
  "(let ((me (as-str (whoami)))) (let ((parts (list/foldl (lambda (acc room) (let* ((rf (chat/row-fields room)) (rid (chat/room-id-of rf)) (peer (chat/dm-peer-from-title (dict-get rf \"title\") me)) (rows (chat/history rid))) (let ((rj (list/foldl (lambda (a row) (let ((f (chat/row-fields row))) (string-append a (if (string-eq a \"\") \"\" \",\") (dict-set* \"{}\" (list \"id\" (chat/row-id row) \"from\" (chat/msg-from f) \"at\" (as-str (dict-get f \"created_at\")) \"body\" (chat/msg-body f)))))) \"\" rows))) (string-append acc (if (string-eq acc \"\") \"\" \",\") (dict-set* \"{}\" (list \"room\" rid \"peer\" peer \"rows\" (string-append \"[\" rj \"]\"))))))) \"\" (chat/dms)))) (dict-set* \"{}\" (list \"rooms\" (string-append \"[\" parts \"]\")))))")

;;; ---------------------------------------------------------------------
;;; autolith control
;;; ---------------------------------------------------------------------

(defparameter *al-bin* (cfg-str "autolith" "bin" "autolith"))
(defparameter *al-session-id* (cfg-str "autolith" "session_id" "auto"))
(defparameter *al-poll-secs* (max (cfg-int "autolith" "poll_secs" 2) 1))
(defparameter *al-conv* (cfg-str "autolith" "conv"))
(defparameter *al-max-reply-chars* (cfg-int "autolith" "max_reply_chars" 8000))
(defparameter *al-hard-cap* (cfg-int "autolith" "turn_timeout_secs" 900))
(defparameter *al-settle-secs* (cfg-int "autolith" "settle_secs" 5))
(defparameter *al-start-timeout* (cfg-int "autolith" "start_timeout_secs" 120))

(defun conversations-dir ()
  "Directory holding <conv>/*.sexp chunk files.

   Built by string concatenation: merge-pathnames with a HOME that has no
   trailing slash mangles a relative default into /home/.local/...al
   (found 2026-09-27 on cutover — conv-files found nothing, so no turn
   could ever start). A trailing slash on the config value is tolerated."
  (let ((d (cfg-str "autolith" "conversations_dir")))
    (if (and d (plusp (length d)))
        (if (eql (char d (1- (length d))) #\/)
            d
            (concatenate 'string d "/"))
        (format nil "~a/.local/share/autolith/conversations/" *home*))))

(defun conv-dir-for (conv)
  (concatenate 'string (conversations-dir) conv "/"))

(defun conv-files ()
  "Sorted .sexp chunk files of the standing conversation, oldest first."
  (when (and *al-conv* (plusp (length *al-conv*)))
    (let* ((dir (conv-dir-for *al-conv*))
           (entries (and (probe-file dir) (directory (format nil "~a*.sexp" dir)))))
      (when entries
        (sort entries #'string< :key #'namestring)))))

(defun conv-total-size ()
  (loop for p in (conv-files) sum (or (file-size p) 0)))

(defun truthy-p (v) (and (member v '(t :t) :test #'eq) t))

(defun al-status-records ()
  "((:session \"..\" :conversation \"..\" :pid n :idle b :active b) ...)"
  (multiple-value-bind (out err code)
      (run-capture (list *al-bin* "localgroup" "status" "--sexp") 30)
    (declare (ignore err))
    (when (zerop code)
      (loop for form in (read-sexp-records out)
            when (and (listp form) (eq (first form) :localgroup-status))
              collect (list :session (kid-val form :session-id)
                            :conversation (kid-val form :conversation-id)
                            :pid (kid-val form :pid)
                            :idle (truthy-p (kid-val form :idle-p))
                            :active (truthy-p (kid-val form :active-turn-p)))))))

(defun kid-val (form key)
  "Keyword-arg value in a (:type :key val ...) form. Walks keyword/value
   pairs and tolerates a trailing odd element (never signals)."
  (loop for rest = (rest form) then (cddr rest)
        while (and (consp rest) (consp (cdr rest)))
        when (eq (first rest) key)
          return (second rest)))

(defun read-sexp-records (text)
  "Read every top-level form we can; skip the ones we can't.

   The scratch package (not KEYWORD) is essential: autolith emits
   #A((n) BASE-CHAR ...) values, and reading those in KEYWORD makes
   BASE-CHAR the keyword :BASE-CHAR, which is an invalid array element
   type. The resulting reader error made this skip a line and then parse
   the record's remaining elements as separate forms, so
   al-status-records always returned NIL and no turn could start
   (found 2026-09-27 on cutover)."
  (let ((*package* (find-package :bridge-sexp-read))
        (*read-eval* nil)
        (forms '()))
    (with-input-from-string (s text)
      (loop
        (let ((form (handler-case (read s nil :eof)
                      (error () (skip-to-next-line s) :broken))))
          (when (eq form :eof) (return))
          (unless (eq form :broken) (push form forms)))))
    (nreverse forms)))

(defun skip-to-next-line (s)
  (loop for ch = (read-char s nil #\Newline)
        until (or (null ch) (eql ch #\Newline))))

(defun al-tell (session body)
  (run-capture (list *al-bin* "localgroup" "tell" session body) 30)
  (values))

(defun al-kill (session)
  (run-capture (list *al-bin* "localgroup" "kill" session) 60)
  (values))

(defun pick-session ()
  (let* ((recs (al-status-records))
         (want *al-session-id*))
    (cond ((and want (string/= want "auto"))
           (find want recs :key (lambda (r) (getf r :session)) :test #'string=))
          (t (or (find-if (lambda (r) (and (getf r :idle) (not (getf r :active))))
                          recs)
                 (first recs))))))

;;; ---------------------------------------------------------------------
;;; conversation log parsing — incremental, real Lisp reader
;;;;
;;; Records are pretty-printed forms whose TEXT BEGINS at a line start
;;; with "(:" — exactly the boundary bridge.py's regex split used, so
;;; bytes-consumed bookkeeping is identical. Records are parsed with the
;;; real reader instead of regex-over-strings: truncation/escaping can no
;;; longer silently drop an assistant message (a parse failure is loud).
;;; ---------------------------------------------------------------------

(defparameter *file-cache* (make-hash-table :test 'equal))
;; key: file namestring -> (consumed-bytes pending-string records)

(defparameter *max-pending-bytes* (* 16 1024 1024))

(defun parse-record-form (line)
  (handler-case
      (with-input-from-string (s line)
        (let ((*package* (find-package :keyword))
              (*read-eval* nil))
          (read s)))
    (error () :broken)))

(defun records-for-file (path)
  "Complete records currently in path, parsed with the real reader.

   Cache invariant: (read-upto pending records) where READ-UPTO is the
   file offset we have READ to (which INCLUDES the PENDING tail we have
   not yet parsed). Reading must resume at read-upto — resuming at
   consumed+/-pending duplicates bytes and corrupts the next record
   (found 2026-09-27: the completing record was parsed as garbage and its
   assistant text was silently lost).

   PENDING is the trailing partial record: a reader error at the end of
   the buffer means it is still flushing, so hold it until more bytes
   arrive. If pending ever blows past the sane bound, drop it loudly
   (never wedge the bridge on malformed data)."
  (let* ((key (namestring path))
         (size (file-size path))
         (cache (gethash key *file-cache*))
         (read-upto (if cache (first cache) 0))
         (pending (if cache (second cache) ""))
         (records (if cache (third cache) nil)))
    (cond ((or (null size) (zerop size)) nil)
          ((or (< read-upto 0) (> read-upto size))
           ;; file shrank (rotation edge): re-read from scratch
           (setf (gethash key *file-cache*) (list 0 "" nil))
           (records-for-file path))
          ((and (= read-upto size) (string= pending ""))
           records)
          (t
           (let* ((chunk (with-open-file (f path
                                          ;; file is APPENDED while we tail it;
                                          ;; a final read can land mid-multibyte
                                          ;; char -> strict utf-8 throws (torn
                                          ;; sequence #(148), 2026-09-29). That
                                          ;; throw used to reach main's blanket
                                          ;; handler and kill the XMPP stream.
                                          ;; :replacement makes a torn tail a
                                          ;; placeholder; the watermark re-reads
                                          ;; the real bytes next poll.
                                          :external-format '(:utf-8 :replacement #\?))
                           (file-position f read-upto)
                           (slurp-exact f)))
                  (buf (concatenate 'string pending chunk)))
             (multiple-value-bind (forms rest)
                 (parse-forms-incremental buf)
               (when (and rest (> (length rest) *max-pending-bytes*))
                 (log-line "WARNING: dropping ~d bytes of unparseable conversation data in ~a"
                           (length rest) key)
                 (setf rest ""))
               (let ((all (append records forms)))
                 (setf (gethash key *file-cache*)
                       (list (+ read-upto (length chunk)) rest all))
                 all)))))))

(defun parse-forms-incremental (buf)
  "Read as many complete top-level forms as possible from BUF.
   Returns (values forms remaining-string).

   NOTE: make-string-input-stream with :start/:end reports file-position
   RELATIVE to the substring, so the absolute offset is pos + consumed.
   (Getting this wrong re-reads the same form forever — 2026-09-27.)"
  (let ((forms '())
        (pos 0)
        (len (length buf)))
    (loop
      (let* ((stream (make-string-input-stream buf pos len))
             (form (handler-case
                       (let ((*package* (find-package :bridge-sexp-read))
                             (*read-eval* nil))
                         (read stream nil :eof))
                     (error () :incomplete))))
        (cond ((eq form :eof)
               (return (values (nreverse forms) (subseq buf pos))))
              ((eq form :incomplete)
               (return (values (nreverse forms) (subseq buf pos))))
              (t
               (let ((consumed (file-position stream)))
                 (when (or (null consumed) (zerop consumed))
                   ;; no progress: treat the rest as pending, never spin
                   (return (values (nreverse forms) (subseq buf pos))))
                 (push form forms)
                 (incf pos consumed))))))))

(defun all-new-records ()
  "Every record beyond the persisted watermark, as
   (path seq form), ordered oldest-first. Does NOT touch the watermark."
  (let ((new '()))
    (dolist (path (conv-files))
      (let ((wm (watermark-for path)))
        (dolist (rec (records-for-file path))
          (let ((seq (record-seq rec)))
            (when (and seq (> seq wm))
              (push (list path seq rec) new))))))
    (nreverse new)))

(defun record-seq (form)
  (and (listp form) (kid-val form :seq)))

(defun collect-turn-records (&optional (rounds 3))
  "Records beyond the watermark, re-read from disk each round. If a round
   yields nothing while the agent is idle, wait one poll and try again (a
   turn's final records can land just after the last status poll). After
   ROUNDS attempts, return whatever we have — a genuinely empty turn is
   legitimate, so this must not loop forever."
  (loop for attempt from 1 to rounds
        do (rescan-conversation)
           (let ((new (all-new-records)))
             (cond ((plusp (length new)) (return new))
                   ((= attempt rounds) (return new))
                   (t (log-line "turn produced nothing yet; retry ~d/~d"
                                attempt rounds)
                      (sleep *al-poll-secs*))))))

(defun rescan-conversation ()
  "Drop the incremental parse cache so the next records-for-file re-reads
   from disk. Called at turn end: the cache is keyed on bytes read, and a
   turn's final records can land after the last poll, so the answer was
   occasionally collected as 0 records while the reply sat in the file
   (observed 2026-09-27 on a pp-dm turn). A full re-parse of the 20MB
   standing conversation costs ~0.6s — cheap insurance."
  (dolist (p (conv-files))
    (remhash (namestring p) *file-cache*)))

(defun advance-watermarks (new-records)
  (dolist (item new-records)
    (bump-watermark (first item) (second item))))

;;; ---------------------------------------------------------------------
;;; reply extraction
;;; ---------------------------------------------------------------------

(defun collect-strings (obj)
  "Every string atom inside a parsed form (base-char arrays included —
the reader gives us real strings for #A((n) BASE-CHAR . \"...\"))."
  (typecase obj
    (string (list obj))
    (cons (append (collect-strings (car obj))
                  (collect-strings (cdr obj))))
    (vector (loop for x across obj append (collect-strings x)))
    (t nil)))

(defun json-message-texts (s)
  "If S parses as an assistant message item JSON, its output_text parts."
  (handler-case
      (let ((item (json-parse s)))
        (when (and (string= (or (jget item "type") "") "message")
                   (string= (or (jget item "role") "") "assistant"))
          (loop for c in (or (jget item "content") ())
                when (and (string= (or (jget c "type") "") "output_text")
                          (jget c "text"))
                  collect (jget c "text"))))
    (error () nil)))

(defun reply-texts (recs)
  "Assistant text messages from PROVIDER-ITEM records, in order."
  (let ((texts '()))
    (dolist (form recs)
      (when (and (listp form) (eq (first form) :provider-item))
        (dolist (s (collect-strings form))
          (when (and (plusp (length s)) (eql (char s 0) #\{))
            (let ((more (json-message-texts s)))
              (when more (setf texts (append texts more))))))))
    texts))

(defun last-user-operation-echo (recs)
  "RESULT echo of a local lisp/slash USER-OPERATION, as a fallback."
  (let ((uo (loop for form in recs
                  when (and (listp form) (eq (first form) :user-operation))
                    collect form)))
    (when uo
      (let ((strings (collect-strings (first (last uo)))))
        (when (> (length strings) 1) (first (last strings)))))))

(defun reply-text (recs)
  (let ((texts (remove-if (lambda (s) (zerop (length (trim s))))
                          (reply-texts recs))))
    (if texts
        (format nil "~{~a~^~%~%~}" texts)
        (or (last-user-operation-echo recs) ""))))

;;; ---------------------------------------------------------------------
;;; chunking + reply policy
;;; ---------------------------------------------------------------------

(defun chunk-text (text &optional (size 1400))
  "Split on blank lines, hard-split oversized paragraphs, keep chunks
under SIZE. Mirrors bridge.py's chunk_text."
  (let ((chunks '()) (buf ""))
    (labels ((hard-split (s)
               (loop for i below (length s) by size
                     collect (subseq s i (min (length s) (+ i size))))))
      (dolist (para (split-blank text))
        (dolist (piece (if (> (length para) size) (hard-split para) (list para)))
          (cond ((and (plusp (length buf))
                      (> (+ (length buf) (length piece) 2) size))
                 (push buf chunks)
                 (setf buf piece))
                (t (setf buf (if (plusp (length buf))
                                 (format nil "~a~%~%~a" buf piece)
                                 piece)))))))
    (when (plusp (length buf)) (push buf chunks))
    (nreverse chunks)))

(defun split-blank (text)
  "Split on one-or-more blank lines."
  (let ((parts '()) (buf '()))
    (dolist (line (split-seq text #\Newline))
      (if (zerop (length (trim line)))
          (progn (when buf
                   (push (format nil "~{~a~^~%~}" (nreverse buf)) parts)
                   (setf buf nil)))
          (push line buf)))
    (when buf (push (format nil "~{~a~^~%~}" (nreverse buf)) parts))
    (nreverse parts)))

(defun reply-policy (surface)
  "surface: :xmpp-private | :xmpp-group | :pp-dm -> :stream or :consolidate."
  (let ((want (case surface
                (:pp-dm (cfg-str "pp" "reply_policy"))
                (:xmpp-private (cfg-str "bridge" "reply_policy_private"))
                (:xmpp-group (cfg-str "bridge" "reply_policy_group")))))
    (cond ((string-equal want "stream") :stream)
          ((string-equal want "consolidate") :consolidate)
          (t (if (eq surface :xmpp-private) :stream :consolidate)))))

(defun consolidate-prefix (surface)
  "MUST start with a plain word: localgroup tell treats leading-paren
input as a local Lisp form, and an unparseable form hangs the turn in
the Lisp debugger."
  (let ((label (case surface
                 (:xmpp-private "PRIVATE CHAT MESSAGE")
                 (:xmpp-group "GROUP CHAT MESSAGE")
                 (:pp-dm "PP DM MESSAGE"))))
    (format nil "~a - do not narrate as you work. Send one consolidated reply at the end.~%~%"
            label)))

;;; ---------------------------------------------------------------------
;;; parked (undelivered) texts — parked on failure, flushed later
;;; ---------------------------------------------------------------------

(defun park-pending (peer surface text)
  (setf (getf *state* :parked)
        (append (getf *state* :parked)
                (list (list :peer peer :surface surface :text text))))
  (save-state)
  (log-line "parked undelivered text for ~a (~d parked)"
            peer (length (getf *state* :parked))))

(defun flush-parked ()
  (loop for item = (first (getf *state* :parked))
        while item
        do (let ((peer (getf item :peer))
                 (surface (getf item :surface))
                 (text (getf item :text)))
             (if (deliver-once peer surface text)
                 (progn
                   (setf (getf *state* :parked) (rest (getf *state* :parked)))
                   (save-state)
                   (log-line "flushed parked delivery to ~a" peer))
                 (return)))))

(defun deliver-once (peer surface text)
  "Send TEXT to PEER. Returns t when it landed. Logs the attempt: silent
   delivery was the failure mode this bridge exists to fix."
  (log-line "deliver ~a (~d chars) to ~a" surface (length text) peer)
  (ecase surface
    (:pp-dm (pp-say-with-retry peer text))
    ((:xmpp-private :xmpp-group)
     ;; clear the typing indicator just before the body lands
     (when (eq surface :xmpp-private)
       (ignore-errors (xmpp-send-state peer :active)))
     (handler-case (progn (xmpp-send-message peer surface text) t)
       (error (e) (log-line "send to ~a failed: ~a" peer e) nil)))))

;;; ---------------------------------------------------------------------
;;; the turn engine
;;;
;;; One agent turn: mark, tell, wait on PROGRESS (not the clock), collect,
;;; deliver, persist watermarks. wait-for-turn replaces bridge.py's
;;; waited<limit loop, which abandoned any turn over 15 minutes and let
;;; the next turn's fresh watermark consume the answer undelivered.
;;; ---------------------------------------------------------------------

(defparameter *turn* nil)   ; active turn: (:peer .. :surface .. :streamed 0)
(defparameter *reap-peer* nil)  ; owner to show composing during a reap

(defun turn-wait (session)
  "Wait for one turn to finish. Returns :done | :never-started | :timeout.

Activity = autolith reports the turn active, or the conversation log grew
(the log flushes at every provider response end).

Finished = we saw activity, autolith is now idle, and it has stayed idle for
settle-secs. settle-secs is SHORT (default 5s): the agent is idle the instant
the answer is written, so a long quiet window is pure added latency on every
turn (60s of dead air per turn was observed 2026-09-27). The old 60s window
only guarded against a mid-turn idle blip; that is handled instead by
checking, after the settle, whether the turn actually produced content (see
collect-turn-records), which retries briefly rather than stalling everyone."
  (let ((waited 0) (started nil) (last-size (conv-total-size))
        (last-activity (now)) (last-typing 0))
    (loop
      (sleep *al-poll-secs*)
      (incf waited *al-poll-secs*)
      ;; keep the xmpp stream warm while the agent works
      (ignore-errors (xmpp-poll-nonblocking))
      ;; deliver narration as it flushes while the turn runs
      (when *turn* (ignore-errors (stream-poll nil)))
      ;; refresh "is typing" while work is in progress. Covers both a live
      ;; turn (*turn*) and a reap, which has no *turn* but can wait minutes.
      (when (> (- (now) last-typing) *typing-refresh-secs*)
        (let ((peer (cond ((and *turn* (eq (getf *turn* :surface) :xmpp-private))
                           (getf *turn* :peer))
                          ((and (not *turn*) *reap-peer*) *reap-peer*))))
          (when peer
            (setf last-typing (now))
            (ignore-errors (xmpp-send-state peer :composing)))))
      (let ((cur (find session (al-status-records)
                       :key (lambda (r) (getf r :session)) :test #'string=)))
        (when (and cur (or (getf cur :active) (not (getf cur :idle))))
          (setf started t last-activity (now)))
        (let ((size (conv-total-size)))
          (when (> size last-size)
            (setf last-size size started t last-activity (now))))
        (when (and started cur (getf cur :idle) (not (getf cur :active))
                   (>= (- (now) last-activity) *al-settle-secs*))
          (return :done))
        (when (and (not started) (> waited *al-start-timeout*))
          (return :never-started))
        (when (> waited *al-hard-cap*)
          (return :timeout))))))

(defun cap-reply (text)
  (if (> (length text) *al-max-reply-chars*)
      (concatenate 'string (subseq text 0 *al-max-reply-chars*)
                   (format nil "~%...[truncated]"))
      text))

(defun turn-floor ()
  "Highest record seq already on disk when this turn's prompt went out.

   Heartbeat turns share the standing conversation, so their replies (a bare
   \"OK\") are 'new records' to a watermark but are not ours to deliver. They
   used to be swept into the joined reply; once streaming went live they
   arrived as stray two-character messages at the head of the turn. Records
   at or below this seq belong to whoever ran before us."
  (and *turn* (getf *turn* :floor)))

(defun above-floor (new)
  (let ((floor (turn-floor)))
    (if floor
        (remove-if (lambda (item) (<= (second item) floor)) new)
        new)))

(defun current-max-seq ()
  "Seq of the newest record already on disk (0 when the log is empty)."
  (let ((m 0))
    (dolist (item (all-new-records))
      (when (> (second item) m) (setf m (second item))))
    m))

(defun turn-collect-and-deliver (rec session)
  "Collect everything since the persisted watermarks, deliver per policy,
then advance + persist the watermarks. Returns :delivered | :parked.

Watermarks advance past every new record (including other actors' turns in
this conversation) so nothing is re-read, but only records above the turn
floor are delivered. On a :stream surface the narration already went out
live, so only texts past :streamed are sent here."
  (declare (ignore session))
  ;; re-read from disk and retry briefly if empty: the turn's last records
  ;; can land after the final poll (silent 0-record collection was observed
  ;; on a pp-dm turn), and a mid-turn idle blip could exit the wait early
  (let* ((all (collect-turn-records))
         (new (above-floor all))
         (forms (mapcar #'third new))
         (texts (remove-if (lambda (s) (zerop (length (trim s))))
                           (reply-texts forms)))
         (surface (getf *turn* :surface))
         (peer (getf *turn* :peer))
         (streaming (eq (reply-policy surface) :stream))
         (streamed (if streaming (or (getf *turn* :streamed) 0) 0))
         (remaining (if streaming
                        (subseq texts (min streamed (length texts)))
                        nil)))
    (log-line "turn collected: ~d new records (~d ours), ~d assistant text(s) (~d streamed)"
              (length all) (length new) (length texts) streamed)
    (cond
      ((and streaming texts (null remaining))
       ;; every text already delivered live: nothing left to send
       (advance-watermarks all) (save-state)
       :delivered)
      (texts
       (let* ((final (if streaming
                         (format nil "~{~a~^~%~%~}" remaining)
                         (or (first (last texts))
                             (last-user-operation-echo forms)
                             "(no text output)")))
              (out (cap-reply final)))
         (if (deliver-once peer surface out)
             (prog1 :delivered
               (advance-watermarks all) (save-state))
             (progn (park-pending peer surface out)
                    (advance-watermarks all) (save-state)
                    :parked))))
      (t
       ;; nothing of ours is textual: still advance so tool noise and other
       ;; actors' turns never leak into the next delta
       (advance-watermarks all) (save-state)
       (if (deliver-once peer surface "(no text output)")
           :delivered
           (progn (park-pending peer surface "(no text output)")
                  :parked))))))

(defun stream-poll (rec)
  "Streaming surfaces deliver each assistant text as it flushes. Called
from turn-wait so narration lands live, and once more at turn end. Only a
successful send advances :streamed, so a failed fragment is retried on the
next poll instead of being logged as sent and lost. Records at or below
the turn floor are someone else's turn (a heartbeat, typically) and are
never delivered."
  (declare (ignore rec))
  (when (eq (reply-policy (getf *turn* :surface)) :stream)
    (let* ((new (above-floor (all-new-records)))
           (forms (mapcar #'third new))
           (texts (remove-if (lambda (s) (zerop (length (trim s))))
                             (reply-texts forms)))
           (delivered (getf *turn* :streamed 0)))
      (when (> (length texts) delivered)
        (let ((n delivered))
          (dolist (text (subseq texts delivered))
            (when (deliver-once (getf *turn* :peer) (getf *turn* :surface) (cap-reply text))
              (incf n)))
          (setf (getf *turn* :streamed) n
                (getf *turn* :streamed-watermarks) new))))))

(defun run-turn (peer surface prompt)
  "One full turn. Returns :delivered | :parked | :failed | :no-session."
  (let ((rec (pick-session)))
    (unless (and rec (getf rec :conversation))
      (deliver-once peer surface "(no autolith session available)")
      (return-from run-turn :no-session))
    (let ((session (getf rec :session)))
      (turn-begin)
      (setf *turn* (list :peer peer :surface surface :streamed 0
                                :started (now) :floor (current-max-seq)))
      (log-line "turn start: session ~a surface ~a peer ~a"
                session surface peer)
      (al-tell session prompt)
      (let ((verdict (turn-wait session)))
        (log-line "turn over: ~a (~a) session ~a"
                  verdict
                  (ecase verdict
                    (:done "turn completed")
                    (:never-started "no activity; tell may not have landed")
                    (:timeout "hard cap reached"))
                  session)
        (stream-poll rec)
        (let ((result (turn-collect-and-deliver rec session)))
          (ignore-errors (sync-tasks))
          (setf *turn* nil)
          (turn-end)
          (when (eq verdict :never-started)
            ;; say so — the human should not have to ask "how did it go"
            (deliver-once peer surface
                          "(the turn never started; the agent may be wedged — send: reset)"))
          result)))))

(defun recover-agent ()
  "Kill the current agent session and relaunch via start-sessions.sh."
  (log-line "recovering agent (kill + resume)")
  (let ((rec (pick-session)))
    (when (and rec (getf rec :session))
      (al-kill (getf rec :session))))
  (sleep 2)
  (let ((script (cfg-str "bridge" "start_script"
                         (merge-pathnames "start-sessions.sh" *harness-dir*))))
    (run-capture (list "/bin/sh" script) 120))
  (loop repeat 20
        do (sleep 3)
           (let ((recs (al-status-records)))
             (when recs
               (log-line "agent back as session ~a" (getf (first recs) :session))
               (return (first recs))))))

(defun baseline-watermarks ()
  "On a first run (no persisted state), mark the standing conversation as
   already seen WITHOUT delivering anything.

   Without this, the first turn collects the entire conversation (6928
   records observed on cutover) and would deliver the last historical
   assistant message as though it answered the incoming request. Records
   are still parsed so every chunk file gets a baseline."
  (when (null (getf *state* :watermarks))
    (let ((n 0))
      (dolist (path (conv-files))
        (let ((recs (records-for-file path)))
          (dolist (rec recs)
            (let ((seq (record-seq rec)))
              (when seq (bump-watermark path seq) (incf n))))))
      (save-state)
      (log-line "baseline: marked ~d existing records as seen (first run)" n))))

(defun session-idle-p (session)
  (let ((cur (find session (al-status-records)
                   :key (lambda (r) (getf r :session)) :test #'string=)))
    (and cur (getf cur :idle) (not (getf cur :active)))))

(defun reap-orphan ()
  "Recover a turn that was in flight when the bridge died.

   If the marker is present and the turn is (or becomes) finished, park its
   answer for delivery so the next turn's watermark cannot consume it
   undelivered. The xmpp connection is not up yet here, so delivery goes
   through the parked queue and the main loop flushes it.

   Fast path: if the agent is ALREADY idle, do not run the full turn-wait —
   the orphaned turn is over, so collecting is enough. Waiting out
   start_timeout_secs here cost ~2 min on a restart over a finished turn
   (observed 2026-09-27)."
  (flush-parked)
  (unwind-protect
       (let ((age (turn-mark-age)))
         (when (and age (> age 5) (< age (* 6 3600)))
           (let ((rec (pick-session)))
             (when (and rec (getf rec :session))
               (let ((verdict
                       (if (session-idle-p (getf rec :session))
                           (progn
                             (log-line "reaper: orphaned turn already finished")
                             :done)
                           (progn
                             (log-line "reaper: turn in flight (~ds old), waiting" age)
                             ;; a reap can take minutes; keep the owner
                             ;; informed the whole time (turn-wait refreshes)
                             (setf *reap-peer* (first (cfg-list "bridge" "allow")))
                             (turn-wait (getf rec :session))))))
                 (log-line "reaper: orphaned turn ended: ~a" verdict)
                 (let* ((new (collect-turn-records))
                        (texts (remove-if (lambda (s) (zerop (length (trim s))))
                                          (reply-texts (mapcar #'third new)))))
                   (when texts
                     (let ((peer (first (cfg-list "bridge" "allow"))))
                       (when peer
                         (park-pending
                          peer :xmpp-private
                          (cap-reply
                           (format nil "picking up where I left off:~%~%~a"
                                   (first (last texts))))))))
                   (advance-watermarks new) (save-state)))))))
    ;; always clear the marker: leaving it set makes the next start re-reap
    (setf *reap-peer* nil)
    (turn-end)))

;;; ---------------------------------------------------------------------
;;; xmpp client — openssl s_client tunnel + streaming stanza reader
;;;
;;; /usr/bin/openssl s_client -quiet -starttls xmpp performs the TLS
;;; upgrade; we speak plain XMPP over its stdin/stdout pipes.
;;; ---------------------------------------------------------------------

(defparameter *conn* nil)
;; (:proc .. :in .. :out .. :buf ".." :jid .. :host .. :password ..)

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

(defparameter *openssl-last-error* nil)

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
                (when (eq el :stream-close)
                  (error "xmpp stream closed"))
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

;; Client-side indicators expire, so refresh while work is in progress.
(defparameter *typing-refresh-secs* 15)

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
               ;; removed (kick/displacement/affiliation) or join error: heal
               ((or (equal type "unavailable") (equal type "error"))
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
                      (handle-dm bare (trim body))
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

(defun enqueue (peer surface body)
  (let ((item (find peer *queue* :key (lambda (q) (getf q :peer))
                    :test #'string=)))
    (if item
        (push body (getf item :bodies))
        (push (list :peer peer :surface surface :bodies (list body))
              *queue*))))

(defun queue-flatten (item)
  "Oldest body first."
  (nreverse (getf item :bodies)))

;;; ---------------------------------------------------------------------
;;; pp dm poller (one consolidated turn per batch, like bridge.py)
;;; ---------------------------------------------------------------------

(defparameter *pp-cursors* (make-hash-table :test 'equal)) ; room -> newest at
(defparameter *pp-seen* (make-hash-table :test 'equal))    ; row id -> t
(defparameter *pp-primed* nil)
(defparameter *pp-libs-loaded* nil)
(defparameter *pp-pending* (make-hash-table :test 'equal)) ; peer -> bodies

(defun pp-poll ()
  (handler-case
      (progn
        (unless *pp-libs-loaded*
          (pp-load-libs)
          (setf *pp-libs-loaded* t))
        (let* ((val (pp-eval *pp-poll-expr* *pp-poll-timeout*))
               (data (if (stringp val) (json-parse val) val))
               (rooms (or (jget data "rooms") ())))
          (dolist (room rooms)
            (let* ((rid (format nil "~a" (jget room "room")))
                   (peer (format nil "~a" (jget room "peer")))
                   (rows-raw (jget room "rows"))
                   (rows (if (stringp rows-raw) (json-parse rows-raw) rows-raw)))
              (let ((newest (gethash rid *pp-cursors* "")))
                (dolist (row (or rows ()))
                  (let* ((rid-row (format nil "~a" (jget row "id")))
                         (at (jget row "at"))
                         (at-str (cond ((stringp at) at)
                                       ((numberp at) (write-to-string at))
                                       (t "")))
                         (frm (format nil "~a" (jget row "from")))
                         (body (format nil "~a" (jget row "body"))))
                    (when (and (plusp (length rid-row))
                               (not (gethash rid-row *pp-seen*)))
                      (setf (gethash rid-row *pp-seen*) t)
                      (when (and at-str (string> at-str newest))
                        (setf newest at-str))
                      (when (and *pp-primed*
                                 (member frm *pp-allow* :test #'string=)
                                 (or (zerop (length at-str))
                                     (null (gethash rid *pp-cursors*))
                                     (string>= at-str (gethash rid *pp-cursors* ""))))
                        (push body (gethash peer *pp-pending* '()))
                        ;; mirror the human's side into the durable inbox
                        (ignore-errors
                         (pp-eval (format nil "(inbox/add ~a \"reply\" ~a)"
                                          (pp-lisp-str frm)
                                          (pp-lisp-str body)))))))
                (setf (gethash rid *pp-cursors*) newest))))
          (setf *pp-primed* t))
        ;; launch one turn per pending peer when no turn is running
        (unless *turn*
          (loop for peer being the hash-keys of *pp-pending*
                do (let ((bodies (nreverse (gethash peer *pp-pending*))))
                     (remhash peer *pp-pending*)
                     (when bodies
                       (run-pp-turn peer bodies))
                     (return))))))
    (error (e)
      (let ((msg (format nil "~a" e)))
        (when (search "unbound" msg)
          (setf *pp-libs-loaded* nil))
        (log-line "pp dm poll error: ~a" msg)))))

(defun run-pp-turn (peer bodies)
  (let ((text (format nil "~{~a~^~%~}" bodies)))
    (log-line "pp dm from ~a (~d chars)" peer (length text))
    (if (string-equal (trim text) "reset")
        (progn
          (deliver-once peer :pp-dm "restarting the agent (kill + resume, ~60s)...")
          (recover-agent)
          (deliver-once peer :pp-dm "agent back online"))
        (let ((prompt (if (eq (reply-policy :pp-dm) :stream)
                          text
                          (concatenate 'string
                                       (consolidate-prefix :pp-dm) text))))
          (run-turn peer :pp-dm prompt)))))

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
(defparameter *main-last-flush* 0)
(defparameter *main-last-task-poll* 0)
(defparameter *main-last-xmpp-ping* 0)
;; Last time ANY byte arrived from the xmpp tunnel — stanza, pong, or
;; whitespace — refreshed by every read path. A stream with no inbound
;; bytes for *xmpp-stale-secs* is dead even if TCP still says
;; ESTABLISHED (silently dropped flow); force a reconnect.
(defparameter *last-inbound* (get-universal-time))

(defun main ()
  (load-state)
  (log-line "CL bridge starting (config ~a)" *config-path*)
  ;; NOTE: reap AFTER connecting. reap-orphan may wait on an in-flight turn,
  ;; and running it first took gregor fully offline (no stanza reading, no
  ;; ping answers) until that turn ended — observed 2026-09-27.
  (baseline-watermarks)
  (let ((backoff 5))
    (loop
      ;; connect (or reconnect after any fatal error below)
      (handler-case (progn (xmpp-connect) (setf backoff 5)
                           (reap-orphan))
        (error (e)
          (log-line "connect failed: ~a — retry in ~ds" e backoff)
          (sleep backoff)
          (setf backoff (min (* 2 backoff) 60))
          (return)))
      ;; serve until the stream dies
      (handler-case
          (progn
            (loop
              ;; 1. drain + dispatch xmpp stanzas (up to ~0.5s granularity)
              (let ((stanza (xmpp-next-stanza-with-timeout)))
                (when stanza (dispatch-stanza stanza)))
              ;; 2. keepalive whitespace ping every 60s
              (when (> (- (now) *main-last-keepalive*) 60)
                (setf *main-last-keepalive* (now))
                (xmpp-send " "))
              ;; 2b. XEP-0199 ping every *xmpp-ping-secs*: forces a
              ;; round-trip answer (pong or error iq) even when idle, so
              ;; *last-inbound* stays fresh on a healthy stream.
              (when (> (- (now) *main-last-xmpp-ping*) *xmpp-ping-secs*)
                (setf *main-last-xmpp-ping* (now))
                (xmpp-send (format nil "<iq id='keepalive~d' type='get'><ping xmlns='urn:xmpp:ping'/></iq>" (now))))
              ;; 2c. no inbound bytes for *xmpp-stale-secs* — not even
              ;; ping answers: the flow is dead (silently dropped
              ;; middlebox state). Raise through the normal error path
              ;; below, which closes the tunnel and reconnects.
              (when (> (- (now) *last-inbound*) *xmpp-stale-secs*)
                (error "xmpp stale: no inbound bytes in ~as — reconnecting" *xmpp-stale-secs*))
              ;; 2d. MUC self-heal: fire any due room rejoin (*muc-rejoin*)
              (muc-rejoin-due)
              ;; 3. start a queued turn if none is running
              (when (and *queue* (not *turn*))
                (let ((item (first *queue*)))
                  (setf *queue* (rest *queue*))
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
              ;; 6. picker watcher
              (picker-watch)

              ;; 6b. detached child jobs: announce completions
              (when (> (- (now) *main-last-task-poll*) *task-poll-secs*)
                (setf *main-last-task-poll* (now))
                (ignore-errors (sync-tasks)))
              ;; 7. retry parked deliveries
              (when (getf *state* :parked)
                (when (> (- (now) *main-last-flush*) 30)
                  (setf *main-last-flush* (now))
                  (flush-parked)))))
        (error (e)
          (log-line "main loop error: ~a — reconnecting in ~ds" e backoff)
          (ignore-errors (sb-ext:process-close (getf *conn* :proc)))
          (setf *conn* nil)
          (sleep backoff)
          (setf backoff (min (* 2 backoff) 60)))))))

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

(defparameter *task-poll-secs*
  (max (cfg-int "bridge" "task_poll_secs" 10) 1))

(defparameter *task-notify-chars*
  (max (cfg-int "bridge" "task_notify_chars" 1200) 100))

(defparameter *xmpp-ping-secs*
  ;; send a XEP-0199 ping this often so idle streams get inbound traffic
  (max (cfg-int "bridge" "xmpp_ping_secs" 600) 60))

(defparameter *xmpp-stale-secs*
  ;; no inbound bytes at all for this long => dead flow => reconnect
  (max (cfg-int "bridge" "xmpp_stale_secs" 2700) 300))

(defun plist-val (form key)
  "Plain plist lookup. kid-val assumes a leading type keyword; result.sexp
   has none, its first key carries a value, so kid-val is off by one here."
  (loop for rest = form then (cddr rest)
        while (and (consp rest) (consp (cdr rest)))
        when (eq (first rest) key) return (second rest)))

(defun text-of (v)
  "Coerce a result field to a string; Autolith emits some as
   #A((n) BASE-CHAR ...) vectors."
  (cond ((null v) nil)
        ((stringp v) v)
        ((and (vectorp v) (plusp (length v)) (typep (aref v 0) 'base-char))
         (coerce v 'string))
        (t (format nil "~a" v))))

(defun tasks-dir ()
  "Tasks live beside the conversations: <data>/tasks/."
  (let ((c (conversations-dir)))
    (concatenate 'string
                 (subseq c 0 (1+ (position #\/ c :from-end t
                                           :end (1- (length c)))))
                 "tasks/")))

(defun task-conversation ()
  (or (and *al-conv* (plusp (length *al-conv*)) *al-conv*)
      (getf (first (al-status-records)) :conversation)))

(defun task-namespace ()
  (let ((conv (task-conversation)))
    (when conv (concatenate 'string (tasks-dir) conv "/"))))

(defun child-dirs (dir)
  "Child ids present in DIR (one namespace of the task store)."
  (when (and dir (probe-file dir))
    (loop for p in (directory (concatenate 'string dir "*"))
          for name = (car (last (pathname-directory p)))
          when (and name (string/= name "conversation-picker"))
            collect name)))

(defun child-result (child)
  "Parsed result.sexp for CHILD, or nil while absent or half-written."
  (let ((raw (read-file-string
              (concatenate 'string (task-namespace) child "/result.sexp"))))
    (when (and raw (plusp (length raw)))
      (let ((form (first (read-sexp-records raw))))
        (when (and (listp form)
                   (plist-val form :status)
                   (member :duration-ms form))
          form)))))

(defun task-key (child)
  (concatenate 'string (or (task-conversation) "") "/" child))

(defun known-tasks () (getf *state* :tasks))

(defun known-task (key) (assoc key (known-tasks) :test #'string=))

(defun remember-task (key peer surface delivered)
  (let ((cur (known-task key)))
    (if cur
        (setf (getf (cdr cur) :delivered) delivered)
        (setf (getf *state* :tasks)
              (acons key (list :peer peer :surface surface :delivered delivered
                               :seen (now))
                     (known-tasks))))))

(defun fallback-peer ()
  (or (first (cfg-list "bridge" "allow")) "the owner"))

(defun deliver-notice (peer surface text)
  "Send an out-of-band notice. No composing->active chat-state dance: that
   belongs to a turn."
  (log-line "notice ~a (~d chars) to ~a" surface (length text) peer)
  (ecase surface
    (:pp-dm (pp-say-with-retry peer text))
    ((:xmpp-private :xmpp-group)
     (handler-case (progn (xmpp-send-message peer surface text) t)
       (error (e) (log-line "notice to ~a failed: ~a" peer e) nil)))))

(defun task-headline (form)
  (let ((name (text-of (plist-val form :name)))
        (status (plist-val form :status))
        (ms (plist-val form :duration-ms)))
    (format nil "~a~@[ (~a)~]~@[ [~a]~]"
            (or name "child job")
            (when (numberp ms) (format nil "~,1fs" (/ ms 1000.0)))
            (and status (string-downcase (symbol-name status))))))

(defun task-body (form)
  (let* ((err (text-of (plist-val form :error)))
         (out (text-of (plist-val form :output)))
         (text (if (and err (plusp (length err)))
                   (format nil "error: ~a" err)
                   (string-trim '(#\Space #\Newline #\Return) (or out ""))))
         (n *task-notify-chars*))
    (if (> (length text) n)
        (concatenate 'string (subseq text 0 n) "...[truncated]")
        text)))

(defun announce-task (child)
  (let* ((key (task-key child))
         (task (known-task key))
         (form (and task (not (getf (cdr task) :delivered))
                    (child-result child))))
    (when form
      (let ((peer (or (getf (cdr task) :peer) (fallback-peer)))
            (surface (or (getf (cdr task) :surface) :xmpp-private))
            (text (format nil "background job finished: ~a~%~a"
                          (task-headline form) (task-body form))))
        (log-line "child job ~a finished -> ~a" child peer)
        (if (deliver-notice peer surface text)
            (log-line "announced child job ~a to ~a" child peer)
            (park-pending peer surface text))
        (setf (getf (cdr task) :delivered) t)
        (save-state)))))

(defun sync-tasks ()
  "Adopt new children, then announce any that finished. A child seen while a
   turn runs inherits that turn's peer; the rest fall back to the owner."
  (let ((dir (task-namespace)))
    (when dir
      (unless (getf *state* :tasks-baselined)
        (dolist (child (child-dirs dir))
          (remember-task (task-key child) nil nil t))
        (setf (getf *state* :tasks-baselined) t)
        (save-state)
        (log-line "task store baselined (~d child jobs on disk)"
                  (length (known-tasks)))
        (return-from sync-tasks))
      ;; a child adopted mid-turn by the periodic poll may have landed on the
      ;; fallback peer; while the turn is still open, claim it for its peer
      (when *turn*
        (let ((started (or (getf *turn* :started) 0)))
          (dolist (child (child-dirs dir))
            (let ((task (known-task (task-key child))))
              (when (and task
                         (not (getf (cdr task) :delivered))
                         (>= (or (getf (cdr task) :seen) 0) started))
                (setf (getf (cdr task) :peer) (getf *turn* :peer)
                      (getf (cdr task) :surface) (getf *turn* :surface)))))))
      (dolist (child (child-dirs dir))
        (unless (known-task (task-key child))
          (remember-task (task-key child)
                         (or (and *turn* (getf *turn* :peer)) (fallback-peer))
                         (or (and *turn* (getf *turn* :surface)) :xmpp-private)
                         nil)
          (save-state)
          (log-line "tracking child job ~a" child)))
      (dolist (child (child-dirs dir))
        (announce-task child)))))

(unless (getenv* "SAGUARO_NO_MAIN")
  (main))
