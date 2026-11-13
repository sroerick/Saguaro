;;;; pricklypear.lisp -- the Pricklypear habitat surface: the eval client

;;;; (curl plus a bearer token), send with retry, durable cursors, and the
;;;; poller that turns habitat DMs into turns (:pp-dm).

(defpackage :SG.PP
  (:use :CL :SG.CORE :SG.AUTOLITH)
  (:export
   #:*PP-ON*
   #:*PP-BASE*
   #:*PP-TOKEN-FILE*
   #:*PP-USER*
   #:*PP-AUTH*
   #:*PP-POLL-SECS*
   #:*PP-POLL-TIMEOUT*
   #:*PP-CHUNK-CHARS*
   #:*PP-ALLOW*
   #:*PP-INBOX-LIB*
   #:PP-TOKEN
   #:*PP-BODY-TMP*
   #:CURL-BIN
   #:PP-RAW
   #:PP-EVAL
   #:PP-LOAD-LIBS
   #:PP-LISP-STR
   #:PP-SAY-ONCE
   #:PP-SAY-WITH-RETRY
   #:*PP-POLL-EXPR-2ARG*
   #:*PP-POLL-EXPR-1ARG*
   #:*PP-POLL-EXPR*
   #:*PP-POLL-EXPR-CHOICE*
   #:*PP-POLL-LAST-FLIP*
   #:*PP-CURSORS*
   #:*PP-SEEN*
   #:*PP-PRIMED*
   #:*PP-LIBS-LOADED*
   #:*PP-PENDING*
   #:*PP-CURSOR-FILE*
   #:PP-LOAD-CURSORS
   #:PP-SAVE-CURSORS
   #:NIL
   #:PP-POLL
   #:RUN-PP-TURN))
(in-package :SG.PP)


(defparameter *pp-on* (and (transport-on-p "pp")
                           (cfg-bool* "pp" "enabled")
                           (cfg-str "pp" "base")))

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
                    (pp-lisp-str (cfg-str "pp" "user" "gregor")) (pp-lisp-str text)))))
                      ;; the row is AUTHOR-attributed: inbox/add is
                      ;; (lambda (from kind body)) over one shared journal
                      ;; with per-user read cursors - the inbound mirror
                      ;; (:2128) files with author=frm, this outbound with
                      ;; author=gregor. by design; if this bridge ever
                      ;; serves a second identity, lift gregor to config.

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
(defparameter *pp-poll-expr-2arg*
  "(let* ((me (as-str (whoami))) (rooms (chat/dms))) (let ((parts (list/foldl (lambda (acc rk) (let* ((room (dict-get rooms rk)) (rid (as-str (dict-get room \"room_id\"))) (peer (chat/dm-peer-from-title (dict-get room \"title\") me)) (rows (chat/history rid 50)) (rj (list/foldl (lambda (a rk2) (let* ((row (dict-get rows rk2)) (item (dict-set* \"{}\" (list \"id\" rk2 \"from\" (as-str (dict-get row \"from\")) \"at\" (as-str (dict-get row \"created_at\")) \"body\" (as-str (dict-get row \"body\")))))) (string-append a (if (string-eq a \"\") \"\" \",\") item))) \"\" (dict-keys rows)))) (string-append acc (if (string-eq acc \"\") \"\" \",\") (dict-set* \"{}\" (list \"room\" rid \"peer\" peer \"rows\" (string-append \"[\" rj \"]\")))))) \"\" (dict-keys rooms)))) (dict-set* \"{}\" (list \"rooms\" (string-append \"[\" parts \"]\")))))")

;; Kept as a fallback: the pp kernel's chat/history signature changed under a
;; running bridge on 2026-10-30 (room -> room+limit) and the poll expression
;; started failing with "arity mismatch", which silently dropped every DM for
;; a day. Either shape is now selectable; see the error handler in pp-poll.
(defparameter *pp-poll-expr-1arg*
  "(let ((me (as-str (whoami)))) (let ((parts (list/foldl (lambda (acc room) (let* ((rf (chat/row-fields room)) (rid (chat/room-id-of rf)) (peer (chat/dm-peer-from-title (dict-get rf \"title\") me)) (rows (chat/history rid))) (let ((rj (list/foldl (lambda (a row) (let ((f (chat/row-fields row))) (string-append a (if (string-eq a \"\") \"\" \",\") (dict-set* \"{}\" (list \"id\" (chat/row-id row) \"from\" (chat/msg-from f) \"at\" (as-str (dict-get f \"created_at\")) \"body\" (chat/msg-body f)))))) \"\" rows))) (string-append acc (if (string-eq acc \"\") \"\" \",\") (dict-set* \"{}\" (list \"room\" rid \"peer\" peer \"rows\" (string-append \"[\" rj \"]\"))))))) \"\" (chat/dms)))) (dict-set* \"{}\" (list \"rooms\" (string-append \"[\" parts \"]\")))))")

(defparameter *pp-poll-expr* *pp-poll-expr-2arg*)
(defparameter *pp-poll-expr-choice* :2arg)
(defparameter *pp-poll-last-flip* 0)


;;; ---------------------------------------------------------------------
;;; pp dm poller (one consolidated turn per batch, like bridge.py)
;;; ---------------------------------------------------------------------

(defparameter *pp-cursors* (make-hash-table :test 'equal)) ; room -> newest at
(defparameter *pp-seen* (make-hash-table :test 'equal))    ; row id -> t
(defparameter *pp-primed* nil)
(defparameter *pp-libs-loaded* nil)
(defparameter *pp-pending* (make-hash-table :test 'equal)) ; peer -> bodies
(defparameter *pp-cursor-file* "/home/al/saguaro-live/harness/pp-dm-cursors.sexp")

(defun pp-load-cursors ()
  "Restore per-room newest-at cursors saved by a previous bridge life."
  (ignore-errors
   (with-open-file (in *pp-cursor-file* :if-does-not-exist nil)
     (when in
       (let ((alist (read in nil nil)))
         (dolist (kv alist)
           (setf (gethash (car kv) *pp-cursors*) (cdr kv))))))))

(defun pp-save-cursors ()
  "Persist per-room newest-at cursors (atomic tmp+rename)."
  (ignore-errors
   (let ((tmp (concatenate 'string *pp-cursor-file* ".tmp")))
     (with-open-file (out tmp :direction :output :if-exists :supersede)
       (prin1 (let ((acc ()))
                (maphash (lambda (k v) (push (cons k v) acc)) *pp-cursors*)
                acc)
              out))
     (rename-file tmp *pp-cursor-file*))))

(pp-load-cursors)

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
                  (when (plusp (length newest))
                    (setf (gethash rid *pp-cursors*) newest)))))
          (setf *pp-primed* t))
          (pp-save-cursors)
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
        ;; A pp-side signature change must not blackhole DMs: flip to the other
        ;; expression shape (at most once every 5 minutes, so two wrong shapes
        ;; cannot flap).
        (when (and (search "arity mismatch" msg)
                   (> (- (now) *pp-poll-last-flip*) 300))
          (setf *pp-poll-last-flip* (now)
                *pp-poll-expr* (if (eq *pp-poll-expr-choice* :2arg)
                                   *pp-poll-expr-1arg* *pp-poll-expr-2arg*)
                *pp-poll-expr-choice* (if (eq *pp-poll-expr-choice* :2arg)
                                          :1arg :2arg))
          (log-line "pp poll expr -> ~a (pp signature changed: ~a)"
                    *pp-poll-expr-choice* msg))
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
;;; the surface this module owns
;;; ---------------------------------------------------------------------

(register-surface :pp-dm
                  :sender #'pp-say-with-retry
                  :policy (cfg-str "pp" "reply_policy")
                  :label "PP DM MESSAGE")
