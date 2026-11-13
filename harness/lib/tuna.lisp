;;;; tuna.lisp -- the tuna inbox lane (:tuna-inbox): durable inbox rows

;;;; fetched over HTTP wake a turn between chats.

(defpackage :SG.TUNA
  (:use :CL :SG.CORE :SG.AUTOLITH :SG.CHANNEL)
  (:export
   #:*TUNA-ON*
   #:*TUNA-BASE*
   #:*TUNA-INBOX*
   #:*TUNA-TOKEN-FILE*
   #:*TUNA-POLL-SECS*
   #:*TUNA-ALLOW*
   #:*TUNA-PENDING*
   #:*TUNA-PRIMED*
   #:*TUNA-404-LOGGED*
   #:*TUNA-BODY-TMP*
   #:*TUNA-MSG-TMP*
   #:TUNA-GET
   #:TUNA-SAY
   #:RUN-TUNA-TURN
   #:TUNA-POLL))
(in-package :SG.TUNA)


;;; ---------------------------------------------------------------------
;;; tuna inbox poller (tuna.town addressing, card c3208d48)
;;;
;;; Tuna's message log is public and its cursor is SERVER-side, so this
;;; poll is a plain anonymous GET: no key, no local cursor file, and a
;;; restart cannot replay a row (the failure the pp poller was rebuilt
;;; for on 10-27).  The first poll after a start primes: it lets the
;;; cursor pass the backlog and delivers nothing.  A 404 means the
;;; endpoint is not deployed yet - logged once, then skipped quietly.
;;; ---------------------------------------------------------------------

(defparameter *tuna-on* (and (cfg-bool* "tuna" "enabled")
                             (cfg-str "tuna" "base")))
(defparameter *tuna-base*
  (let ((b (cfg-str "tuna" "base" "")))
    (if (plusp (length b)) (string-right-trim "/" b) b)))
(defparameter *tuna-inbox* (cfg-str "tuna" "inbox" "gregor"))
(defparameter *tuna-token-file* (cfg-str "tuna" "token_file"))
(defparameter *tuna-poll-secs* (max 1 (cfg-int "tuna" "poll_secs" 30)))
(defparameter *tuna-allow* (cfg-list "tuna" "allow"))
(defparameter *tuna-pending* (make-hash-table :test 'equal))
(defparameter *tuna-primed* nil)
(defparameter *tuna-404-logged* nil)
(defparameter *tuna-body-tmp* "/tmp/saguaro-tuna-body.json")
(defparameter *tuna-msg-tmp* "/tmp/saguaro-tuna-msg.json")

(defun tuna-get (path)
  "Anonymous GET against [tuna] base. Returns (values body status);
   status 0 when the transport failed."
  (multiple-value-bind (out err code)
      (run-capture (list (curl-bin) "-sS" "-m" "20"
                         "-o" *tuna-body-tmp* "-w" "%{http_code}"
                         (concatenate 'string *tuna-base* path))
                   30)
    (declare (ignore err code))
    (values (or (read-file-string *tuna-body-tmp*) "")
            (or (ignore-errors
                  (parse-integer
                   (string-trim '(#\Space #\Newline #\Return #\Tab) out)
                   :junk-allowed t))
                0))))

(defun tuna-say (peer text)
  "POST /api/msg as this inbox identity. Returns t when the row landed.
   Without a token_file the reply is dropped loudly: reads need no key,
   writes do, and pretending otherwise would park the text forever."
  (let ((tok (and *tuna-token-file*
                  (trim (or (read-file-string *tuna-token-file*) "")))))
    (cond
      ((or (null tok) (zerop (length tok)))
       (log-line "tuna reply to ~a dropped: no token_file configured" peer)
       t)
      (t
       (with-open-file (f *tuna-msg-tmp* :direction :output
                          :if-exists :supersede)
         (format f "{\"to\":\"~a\",\"text\":\"~a\",\"kind\":\"reply\"}"
                 (json-escape peer) (json-escape text)))
       (multiple-value-bind (out err code)
           (run-capture (list (curl-bin) "-sS" "-m" "20" "-X" "POST"
                              "-H" (format nil "Authorization: Bearer ~a" tok)
                              "-H" "Content-Type: application/json"
                              "-d" (concatenate 'string "@" *tuna-msg-tmp*)
                              "-o" "/dev/null" "-w" "%{http_code}"
                              (concatenate 'string *tuna-base* "/api/msg"))
                        30)
         (declare (ignore err code))
         (let ((status (or (ignore-errors
                             (parse-integer
                              (string-trim '(#\Space #\Newline #\Return #\Tab) out)
                              :junk-allowed t))
                           0)))
           (log-line "tuna reply to ~a: HTTP ~a" peer status)
           (= status 201)))))))

(defun run-tuna-turn (peer bodies)
  (let ((text (format nil "~{~a~^~%~}" bodies)))
    (log-line "tuna inbox from ~a (~d chars)" peer (length text))
    (let ((prompt (if (eq (reply-policy :tuna-inbox) :stream)
                      text
                      (concatenate 'string
                                   (consolidate-prefix :tuna-inbox) text))))
      (run-channel-turn peer :tuna-inbox prompt))))

(defun tuna-poll ()
  (handler-case
      (multiple-value-bind (body status)
          (tuna-get (format nil "/api/inbox/~a" *tuna-inbox*))
        (cond
          ((= status 404)
           (unless *tuna-404-logged*
             (setf *tuna-404-logged* t)
             (log-line "tuna inbox 404 at ~a (endpoint not deployed); quiet from here"
                       *tuna-base*)))
          ((/= status 200)
           (log-line "tuna inbox HTTP ~a from ~a" status *tuna-base*))
          (t
           (setf *tuna-404-logged* nil)
           (let* ((data (json-parse body))
                  (rows (or (jget data "messages") ())))
             (if (not *tuna-primed*)
                 (progn
                   (setf *tuna-primed* t)
                   (log-line
                    "tuna inbox ~a primed at cursor ~a (~d backlog row(s) skipped)"
                    *tuna-inbox* (or (jget data "cursor") "?") (length rows)))
                 (dolist (row rows)
                     (let ((frm (format nil "~a" (jget row "from")))
                           (text (format nil "~a" (jget row "body")))
                           (seq (format nil "~a" (jget row "seq")))
                           (kind (format nil "~a" (jget row "kind"))))
                       (cond
                         ((string-equal kind "ack")
                          ;; A seat ack means "seen, queued": no work in it. Waking a
                          ;; turn for one earns another ack, and the pair ping-pongs
                          ;; (11-04: seq 26/29/30, a turn every poll interval).
                          (log-line "tuna inbox: seq ~a ack from ~a (skipped)" seq frm))
                         ((and (plusp (length text))
                               (string/= frm *tuna-inbox*)
                               (or (null *tuna-allow*)
                                   (member frm *tuna-allow* :test #'string=)))
                          (log-line "tuna inbox: seq ~a from ~a" seq frm)
                          (push (format nil "[tuna #~a from ~a] ~a" seq frm text)
                                  (gethash frm *tuna-pending* '())))))))
             (unless *turn*
               (loop for peer being the hash-keys of *tuna-pending*
                     do (let ((bodies (nreverse (gethash peer *tuna-pending*))))
                          (remhash peer *tuna-pending*)
                          (when bodies (run-tuna-turn peer bodies))
                            (return))))))))
    (error (e) (log-line "tuna inbox poll error: ~a" e))))


;;; ---------------------------------------------------------------------
;;; the surface this module owns
;;; ---------------------------------------------------------------------

(register-surface :tuna-inbox
                  :sender #'tuna-say
                  :policy (cfg-str "tuna" "reply_policy")
                  :label "TUNA INBOX MESSAGE")
