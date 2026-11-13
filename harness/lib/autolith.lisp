;;;; autolith.lisp -- the agent-facing library: conversation records, the

;;;; turn engine (tell, wait, collect, deliver), reply policy and chunking,
;;;; the surface delivery registry, owner commands, and the task/notice
;;;; lanes that push detached-child completions to the owner.
;;;; 
;;;; No surface is named here: an adapter registers a sender with
;;;; REGISTER-SURFACE, and everything downstream dispatches through it.

(defpackage :SG.AUTOLITH
  (:use :CL :SG.CORE)
  (:export
   #:*AL-BIN*
   #:*AL-SESSION-ID*
   #:*AL-POLL-SECS*
   #:*AL-CONV*
   #:*AL-MAX-REPLY-CHARS*
   #:*AL-HARD-CAP*
   #:*AL-TURN-WALL-CAP*
   #:*AL-SETTLE-SECS*
   #:*AL-START-TIMEOUT*
   #:CONVERSATIONS-DIR
   #:CONV-DIR-FOR
   #:CONV-FILES
   #:CONV-TOTAL-SIZE
   #:TRUTHY-P
   #:AL-STATUS-RECORDS
   #:KID-VAL
   #:READ-SEXP-RECORDS
   #:SKIP-TO-NEXT-LINE
   #:AL-TELL
   #:AL-KILL
   #:PICK-SESSION
   #:*FILE-CACHE*
   #:*MAX-PENDING-BYTES*
   #:PARSE-RECORD-FORM
   #:RECORDS-FOR-FILE
   #:PARSE-FORMS-INCREMENTAL
   #:ALL-NEW-RECORDS
   #:RECORD-SEQ
   #:COLLECT-TURN-RECORDS
   #:RESCAN-CONVERSATION
   #:ADVANCE-WATERMARKS
   #:COLLECT-STRINGS
   #:JSON-MESSAGE-TEXTS
   #:REPLY-TEXTS
   #:LAST-USER-OPERATION-ECHO
   #:REPLY-TEXT
   #:CHUNK-TEXT
   #:SPLIT-BLANK
   #:REPLY-POLICY
   #:CONSOLIDATE-PREFIX
   #:PARK-PENDING
   #:FLUSH-PARKED
   #:DELIVER-ONCE
   #:*TURN*
   #:*REAP-PEER*
   #:TURN-WAIT
   #:CAP-REPLY
   #:TURN-FLOOR
   #:ABOVE-FLOOR
   #:CURRENT-MAX-SEQ
   #:TURN-COLLECT-AND-DELIVER
   #:STREAM-POLL
   #:RUN-TURN
   #:RECOVER-AGENT
   #:BASELINE-WATERMARKS
   #:SESSION-IDLE-P
   #:REAP-ORPHAN
   #:*BRIDGE-STARTED*
   #:*PAUSE-PATH*
   #:COMMAND-P
   #:FMT-DURATION
   #:CMD-CD-RECENT
   #:CMD-SEXP-FIELD
   #:CMD-CTX-K
   #:CMD-STATUS-RAW
   #:WATCHDOG-PAUSE-EXPIRY
   #:PAUSE-WRITE
   #:CMD-PING
   #:CMD-HELP
   #:CMD-RECENT-INCIDENTS
   #:CMD-STATUS
   #:CMD-RESTART
   #:CMD-COMPACT
   #:CMD-CANARY
   #:CMD-PAUSE
   #:HANDLE-COMMAND
   #:*TASK-NOTIFY-CHARS*
   #:*XMPP-PING-SECS*
   #:*XMPP-STALE-SECS*
   #:PLIST-VAL
   #:TEXT-OF
   #:TASKS-DIR
   #:TASK-CONVERSATION
   #:TASK-NAMESPACE
   #:CHILD-DIRS
   #:CHILD-RESULT
   #:TASK-KEY
   #:KNOWN-TASKS
   #:KNOWN-TASK
   #:REMEMBER-TASK
   #:FALLBACK-PEER
   #:DELIVER-NOTICE
   #:TASK-HEADLINE
   #:TASK-BODY
   #:ANNOUNCE-TASK
   #:*NOTICE-DIGEST*
   #:*NOTICE-DIGEST-SINCE*
   #:*NOTICE-DIGEST-WINDOW*
   #:*NOTICE-DIGEST-MAX*
   #:*NOTICE-DIGEST-CHARS*
   #:QUEUE-NOTICE
   #:FLUSH-NOTICES
    #:SYNC-TASKS
    #:*SURFACES*
    #:REGISTER-SURFACE
    #:SURFACE-PROPERTY
    #:*DEFAULT-SURFACE*
    #:TYPING-INDICATOR
    #:*TYPING-REFRESH-SECS*
    #:REGISTER-POLLER
    #:POLL-SURFACES
    #:REGISTER-STATUS
    #:SURFACE-STATUS-LINE   #:*TASK-POLL-SECS*
))
(in-package :SG.AUTOLITH)


;;; ---------------------------------------------------------------------
;;; autolith control
;;; ---------------------------------------------------------------------

(defparameter *al-bin* (cfg-str "autolith" "bin" "autolith"))
(defparameter *al-session-id* (cfg-str "autolith" "session_id" "auto"))
(defparameter *al-poll-secs* (max (cfg-int "autolith" "poll_secs" 2) 1))
(defparameter *al-conv* (cfg-str "autolith" "conv"))
(defparameter *al-max-reply-chars* (cfg-int "autolith" "max_reply_chars" 8000))
(defparameter *al-hard-cap* (cfg-int "autolith" "turn_timeout_secs" 900))
;; Wall-clock ceiling for one turn. The `waited` counter above accrues poll
;; INTERVALS, so it is not a real time bound; this is. Deliberately generous:
;; real turns run 30-60+ min (see header) and completion is detected by the
;; app reporting it is no longer in a turn (below), not by this number.
(defparameter *al-turn-wall-cap*
  ;; default to the configured hard cap, never below it: local config sets
  ;; turn_timeout_secs = 14400 and real turns run 30-60+ min.
  (cfg-int "autolith" "turn_max_secs" *al-hard-cap*))
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
                            :active (truthy-p (kid-val form :active-turn-p))
                            :waiting (truthy-p
                                      (kid-val form :waiting-for-input-p)))))))

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
               (let* ((all (append records forms))
                      ;; Prune records we have already consumed (seq <= the
                      ;; persisted per-file watermark) so the cache holds only
                      ;; UNCONSUMED records. Without this, the cache retained
                      ;; every parsed form of the growing conversation (49 MB
                      ;; -> ~188 MB live) and, doubled during a full re-parse,
                      ;; exhausted the SBCL heap (2026-10-11). Bounded now.
                      (wm (watermark-for path))
                      (kept (if (plusp wm)
                                (remove-if (lambda (r)
                                             (let ((s (record-seq r)))
                                               (and s (<= s wm))))
                                           all)
                                all)))
                 (setf (gethash key *file-cache*)
                       (list (+ read-upto (length chunk)) rest kept))
                 kept)))))))

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
   (observed 2026-09-27 on a pp-dm turn). Kept: making this a no-op regressed
   collection (a live round trip collected 0 records, 2026-10-11), because a
   turn's records can land in a file the incremental cache has already read
   past. Memory is bounded instead by records-for-file PRUNING consumed
   records, so the cache never retains the whole conversation."
  ;; Only the NEWEST chunk(s) can still be appended to. Dropping the cache for
  ;; every file made turn end re-parse the whole conversation from byte 0: 46
  ;; chunks / 93 MB -> ~800 MB of Lisp objects, which exhausted SBCL's dynamic
  ;; space inside collect-turn-records and killed the bridge (2026-10-30 14:49,
  ;; "Heap exhausted, game over", 82% of 805 MB). Two newest, for rotation
  ;; slack.
  (let* ((files (conv-files))
         (tail (if (> (length files) 2) (last files 2) files)))
    (dolist (p tail)
      (remhash (namestring p) *file-cache*))))

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

;;; ---------------------------------------------------------------------
;;; the surface registry
;;;
;;; An adapter owns its surface: how to send on it, how to refresh chat state,
;;; which reply policy it wants, what a consolidated prompt calls it, and
;;; whether it is private. Adapters register that when they load; nothing here
;;; names a transport.
;;; ---------------------------------------------------------------------

(defparameter *surfaces* (make-hash-table :test #'eq)
  "Surface keyword -> plist. See REGISTER-SURFACE.")

(defparameter *default-surface* :xmpp-private
  "Surface to use when nothing else names one. The bridge sets it at start-up
from the configured transports.")

(defun register-surface (surface &key sender typing policy label private-p)
  "Describe SURFACE: SENDER is (lambda (peer text)), TYPING is
(lambda (peer state)), POLICY is the configured reply policy string, LABEL
names the surface in a consolidated prompt, PRIVATE-P marks a 1:1 surface."
  (setf (gethash surface *surfaces*)
        (list :sender sender :typing typing :policy policy :label label
              :private-p private-p))
  surface)

(defun surface-property (surface key &optional default)
  (getf (gethash surface *surfaces*) key default))

(defun typing-indicator (surface peer state)
  "Ask SURFACE to refresh PEER's chat state, when it has one."
  (let ((fn (surface-property (or surface *default-surface*) :typing)))
    (when fn (ignore-errors (funcall fn peer state)))))

(defparameter *typing-refresh-secs* 15
  "Client-side chat-state indicators expire, so refresh them while work runs.")

(defparameter *surface-pollers* '()
  "Functions run from the turn engine and the main loop: keep a stream warm,
fire a due MUC heal, drain an inbound queue. Each adapter registers one.")

(defun register-poller (function)
  "Add FUNCTION to the adapter ticks run by POLL-SURFACES."
  (pushnew function *surface-pollers* :test #'eq)
  function)

(defun poll-surfaces ()
  "Give every adapter a tick. One adapter's failure never stops the others."
  (dolist (function *surface-pollers*)
    (ignore-errors (funcall function))))

(defparameter *surface-status* '()
  "Functions returning a short status fragment for the owner's /status reply.")

(defun register-status (function)
  "Add FUNCTION to the fragments CMD-STATUS reports."
  (pushnew function *surface-status* :test #'eq)
  function)

(defun surface-status-line ()
  "Comma-separated adapter state for /status: queued work, stream condition."
  (let ((parts (remove nil (mapcar (lambda (fn) (ignore-errors (funcall fn)))
                                   *surface-status*))))
    (if parts (format nil "~{~a~^, ~}" parts) "no adapters reporting")))

(defun reply-policy (surface)
  "SURFACE -> :stream or :consolidate, from what its adapter registered."
  (let ((want (surface-property surface :policy)))
    (cond ((and (stringp want) (string-equal want "stream")) :stream)
          ((and (stringp want) (string-equal want "consolidate")) :consolidate)
          ((surface-property surface :private-p) :stream)
          (t :consolidate))))

(defun consolidate-prefix (surface)
  "MUST start with a plain word: localgroup tell treats leading-paren
input as a local Lisp form, and an unparseable form hangs the turn in
the Lisp debugger."
  (format nil "~a - do not narrate as you work. Send one consolidated reply at the end.~%~%"
          (or (surface-property surface :label) "CHAT MESSAGE")))

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
  "Send TEXT to PEER through the sender its surface registered. Returns t
when it landed. Logs the attempt: silent delivery was the failure mode
this bridge exists to fix."
  (log-line "deliver ~a (~d chars) to ~a" surface (length text) peer)
  (let ((send (surface-property surface :sender)))
    (cond ((null send)
           (log-line "no sender registered for surface ~a; text dropped" surface)
           nil)
          (t (handler-case (progn (funcall send peer text) t)
               (error (e) (log-line "send to ~a failed: ~a" peer e) nil))))))

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
        (last-activity (now)) (last-typing 0)
        (turn-start (now)))
    (loop
      (sleep *al-poll-secs*)
      (incf waited *al-poll-secs*)
        ;; keep every adapter warm while the agent works: the main loop is parked
        ;; here until the turn ends
        (poll-surfaces)
      ;; deliver narration as it flushes while the turn runs
      (when *turn* (ignore-errors (stream-poll nil)))
      ;; refresh "is typing" while work is in progress. Covers both a live
      ;; turn (*turn*) and a reap, which has no *turn* but can wait minutes.
        (when (> (- (now) last-typing) *typing-refresh-secs*)
          (let ((peer (cond ((and *turn* (surface-property (getf *turn* :surface) :private-p))
                             (getf *turn* :peer))
                            ((and (not *turn*) *reap-peer*) *reap-peer*))))
            (when peer
              (setf last-typing (now))
              (typing-indicator (and *turn* (getf *turn* :surface)) peer :composing))))
        (let ((cur (find session (al-status-records)
                       :key (lambda (r) (getf r :session)) :test #'string=)))
        (when (and cur (or (getf cur :active) (not (getf cur :idle))))
          (setf started t last-activity (now)))
        (let ((size (conv-total-size)))
          (when (> size last-size)
            (setf last-size size started t last-activity (now))))
        ;; Finished when the app is out of a turn: :IDLE-P alone is not
        ;; enough, because background child tasks keep :IDLE-P NIL while the
        ;; composer is already accepting input (2026-10-30: 5 live swarm
        ;; children held a finished turn open for 35+ min and starved the
        ;; DM queue behind it).
        ;; :WAITING-FOR-INPUT-P is authoritative: the composer is accepting
        ;; input, so no turn is open. Do NOT also require the settle window --
        ;; live child tasks keep appending records, which refreshes
        ;; last-activity forever and defeated the settle test (2026-10-30: a
        ;; finished turn stayed "in flight" for 35+ minutes).
        (when (and started cur (not (getf cur :active))
                   (or (getf cur :waiting)
                       (and (getf cur :idle)
                            (>= (- (now) last-activity) *al-settle-secs*))))
          (return :done))
        (when (and (not started) (> waited *al-start-timeout*))
          (return :never-started))
        ;; `waited` counts poll INTERVALS, not seconds: a slow status poll
        ;; stretched a nominal 900s cap past 30 minutes (2026-10-30, held the
        ;; queue behind a turn that the app had already finished). Cap on
        ;; wall clock too.
        (when (or (> waited *al-hard-cap*)
                  (> (- (now) turn-start) *al-turn-wall-cap*))
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

;;; --- why a turn came back without text ---------------------------------
;;;
;;; "0 assistant texts" is a symptom, not a diagnosis. A turn can end that way
;;; because the model stopped on tool calls, because the provider returned
;;; nothing visible, because compaction aborted the turn, or because the turn
;;; was cut off. Each leaves different records behind, so read them instead of
;;; repeating one guess (the old stub blamed compaction for all four).

(defparameter *no-text-nudged* nil
  "Set once per turn after the single recovery nudge, so a silent agent cannot
   ping-pong nudges forever.")

(defun records-of-kind (forms kind)
  "Forms among FORMS whose head is KIND."
  (remove-if-not (lambda (f) (and (listp f) (eq (first f) kind))) forms))

(defun record-field (form key)
  "Value of plist KEY in the record FORM, or NIL."
  (let ((tail (member key (rest form))))
    (second tail)))

(defun provider-item-json-kind (form)
  "JSON \"type\" of a :PROVIDER-ITEM form: message, function_call, reasoning,
   function_call_output. NIL when the wire JSON does not parse."
  (let ((json (record-field form :wire-json)))
    (when (stringp json)
      (handler-case (jget (json-parse json) "type") (error () nil)))))

(defun turn-mechanics (forms)
  "Plist of what the turn's own records say: item counts by kind, abort
   reason, and the last context sample's token count."
  (let* ((items (records-of-kind forms :provider-item))
         (kinds (mapcar #'provider-item-json-kind items))
         (aborts (records-of-kind forms :turn-aborted))
         (usage (car (last (records-of-kind forms :context-usage))))
         (sample (and usage (record-field usage :sample))))
    (list :items (length items)
          :messages (count "message" kinds :test #'equal)
          :tool-calls (count "function_call" kinds :test #'equal)
          :reasoning (count "reasoning" kinds :test #'equal)
          :aborted (length aborts)
          :abort-reason (and aborts
                             (or (record-field (car (last aborts)) :reason)
                                 (record-field (car (last aborts)) :condition)))
          :tokens (and sample (record-field sample :tokens)))))

(defun no-text-diagnosis (forms)
  "One sentence naming the mechanical reason this turn wrote no assistant text."
  (let* ((m (turn-mechanics forms))
         (tokens (getf m :tokens)))
    (format nil "~@[~a; ~]~a~@[, context ~dK~]"
            (getf m :abort-reason)
            (cond
              ((plusp (getf m :aborted)) "the turn aborted before writing")
              ((zerop (getf m :items)) "the turn produced no provider response")
              ((plusp (getf m :tool-calls))
               (format nil "the model stopped after ~d tool call~:p and never wrote a message"
                       (getf m :tool-calls)))
              ((plusp (getf m :reasoning))
               "the response carried reasoning but no visible text")
              (t "no assistant message was recorded"))
            (and tokens (round tokens 1000)))))

(defun nudge-for-text (session)
  "Ask once for an assistant message when a turn ended without one. A chat
   surface carries assistant text and nothing else, so this is the difference
   between a reply and a stub. Bounded: one nudge per turn."
  (when (and session (not *no-text-nudged*))
    (setf *no-text-nudged* t)
    (log-line "NO-TEXT TURN: nudging once for an assistant message")
    (al-tell session
             "(the chat surface only carries assistant message text, and your last turn ended without any. Reply now with a short message.)")
    (eq (turn-wait session) :done)))

(defun turn-collect-and-deliver (rec session)
  "Collect everything since the persisted watermarks, deliver per policy,
then advance + persist the watermarks. Returns :delivered | :parked.

Watermarks advance past every new record (including other actors' turns in
this conversation) so nothing is re-read, but only records above the turn
floor are delivered. On a :stream surface the narration already went out
live, so only texts past :streamed are sent here."
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
         ;; actors' turns never leak into the next delta.
         (let ((diagnosis (no-text-diagnosis forms)))
           (log-line "NO-TEXT TURN: 0 assistant texts (~d new, ~d ours): ~a"
                     (length all) (length new) diagnosis)
           (mark-no-text-turn all new *al-conv*)
           (advance-watermarks all) (save-state)
           (if (nudge-for-text session)
               (progn
                 (log-line "NO-TEXT TURN: nudge landed; re-collecting")
                 (turn-collect-and-deliver rec session))
               (let ((msg (format nil "(no reply this turn - ~a. Logged; ask again and I retry.)"
                                  diagnosis)))
                 (if (deliver-once peer surface msg)
                     :delivered
                     (progn (park-pending peer surface msg)
                              :parked)))))))))

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
        (setf *no-text-nudged* nil)
        (setf *turn* (list :peer peer :surface surface :streamed 0 :session session
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
                          peer *default-surface*
                          (cap-reply
                           (format nil "picking up where I left off:~%~%~a"
                                   (first (last texts))))))))
                   (advance-watermarks new) (save-state)))))))
    ;; always clear the marker: leaving it set makes the next start re-reap
    (setf *reap-peer* nil)
    (turn-end)))


;;; ---------------------------------------------------------------------
;;; chat commands (owner-only, standalone, bridge-local -- no agent turn)
;;;
;;; Modeled on openclaw's gateway commands and hermes' /start + /pause:
;;; a standalone "/..." DM from an allowlisted sender is answered HERE,
;;; from local state, with NO agent turn -- so /status still answers when
;;; the provider is dead (the 36h K3CL8Cm outage: chat path up, agent
;;; mute, no way to ask the box anything from a phone). Commands are
;;; standalone messages only; anything not starting with "/" is prose and
;;; goes to the agent exactly as before. Unknown commands get a short
;;; local reply (never a turn, never a silent swallow). Non-allowlisted
;;; senders never reach this code: stanza-allowed-p gates the DM path
;;; upstream. No host shell over chat, no secret reads.
;;; ---------------------------------------------------------------------

(defparameter *bridge-started* (get-universal-time))
(defparameter *pause-path* (home-path ".cache/saguaro-watchdog-paused"))

(defun command-p (body)
  "Standalone command: the entire body starts with '/'."
  (and (plusp (length body)) (char= (char body 0) #\/)))

(defun fmt-duration (secs)
  "~2dh~2,'0dm above an hour, else ~dm~2,'0ds."
  (if (>= secs 3600)
      (format nil "~dh~2,'0dm" (floor secs 3600) (floor (mod secs 3600) 60))
      (format nil "~dm~2,'0ds" (floor secs 60) (mod (floor secs 1) 60))))

(defun cmd-cd-recent (name secs)
  "True within SECS of the last marker touch; touches it otherwise.
Cooldown so /restart //compact //canary spam cannot fight the watchdog."
  (let* ((p (format nil "~a/.cache/saguaro-cmd-~a" *home* name))
         (stamp (ignore-errors (file-write-date p))))
    (if (and stamp (< (- (get-universal-time) stamp) secs))
        t
        (progn
          (ignore-errors
            (with-open-file (f p :direction :output
                                :if-exists :supersede
                                :if-does-not-exist :create)
              (format f "~a~%" (timestamp-string))))
          nil))))

(defun cmd-sexp-field (raw name)
  "The value after :NAME in a `localgroup status --sexp` blob -- quoted
string or keyword, watchdog's regex in plain CL."
  (let* ((pos (search (format nil ":~a" name) raw :test #'char-equal))
         (i (and pos (position-if
                      #'(lambda (c) (not (member c '(#\Space #\Tab))))
                      raw :start (+ pos (length name) 1))))
         (q (and i (char= (char raw i) #\")))
         (end-str (and i q (position #\" raw :start (1+ i))))
         (end-tok (and i (not q)
                       (position-if #'(lambda (c)
                                        (member c '(#\Space #\) #\Newline)))
                                    raw :start i))))
    (cond ((and i q) (and end-str (subseq raw (1+ i) end-str)))
          (i (subseq raw i (or end-tok (length raw))))
          (t nil))))

(defun cmd-ctx-k ()
  "Context meter (K) from the alagent pane, watchdog-style; NIL when absent."
  (multiple-value-bind (out err code)
      (run-capture (list "/usr/bin/tmux" "capture-pane" "-p" "-t" "alagent") 15)
    (declare (ignore err))
    (when (zerop code)
      (let* ((hit (search "ctx [" out))
             (close (and hit (position #\] out :start hit)))
             (i (and close (position-if #'digit-char-p out :start (1+ close))))
             (j (and i (or (position-if-not #'digit-char-p out :start i)
                           (length out)))))
        (and i j (parse-integer out :start i :end j :junk-allowed t))))))

(defun cmd-status-raw ()
  "Raw `localgroup status --sexp` output, or NIL."
  (multiple-value-bind (out err code)
      (run-capture (list *al-bin* "localgroup" "status" "--sexp") 15)
    (declare (ignore err))
    (and (zerop code) (plusp (length (trim out))) out)))

(defun watchdog-pause-expiry ()
  "Universal time when the watchdog pause ends, or NIL."
  (let ((s (read-file-string *pause-path*)))
    (when s
      (let ((n (parse-integer (trim s) :junk-allowed t)))
        (and n (> n (get-universal-time)) n)))))

(defun pause-write (secs)
  (ignore-errors
    (with-open-file (f *pause-path* :direction :output
                       :if-exists :supersede :if-does-not-exist :create)
      (format f "~d~%" (+ (get-universal-time) secs)))))

(defun cmd-ping ()
  (format nil "pong - bridge alive ~a (agent is a separate process; /status for detail)"
          (fmt-duration (- (get-universal-time) *bridge-started*))))

(defun cmd-help ()
  (format nil "bridge-local commands (no agent turn; work even when the model is down):~%
  /ping /status /help~%
  owner ops: /restart /compact /canary /pause <1-72h> | /pause off~%
Anything without a leading / goes to the agent as prose."))

(defun cmd-recent-incidents ()
  (let* ((files (ignore-errors
                  (directory (format nil "~aincidents/*.log" *harness-dir*))))
         (sorted (and files
                      (sort files #'> :key
                            (lambda (f)
                              (or (ignore-errors (file-write-date f)) 0))))))
    (if sorted
        (format nil "recent incidents: ~{~a~^, ~}"
                (mapcar (lambda (f) (enough-namestring f *harness-dir*))
                        (subseq sorted 0 (min 2 (length sorted)))))
        "recent incidents: none")))

(defun cmd-status ()
  (let* ((raw (cmd-status-raw))
         (agent (if raw
                    (format nil "agent ~a [~a] ctx ~aK, session ~a"
                            (or (cmd-sexp-field raw "STATE") "?")
                            (or (cmd-sexp-field raw "MODEL") "?")
                            (or (cmd-ctx-k) "?")
                            (or (cmd-sexp-field raw "SESSION") *al-conv* "?"))
                    "agent: status unavailable"))
         (canary-age (let ((d (ignore-errors
                               (file-write-date
                                (home-path ".cache/saguaro-canary")))))
                       (if d
                           (fmt-duration (- (get-universal-time) d))
                           "never")))
         (pause (let ((e (watchdog-pause-expiry)))
                  (if e
                      (format nil "yes, ~a left"
                              (fmt-duration (- e (get-universal-time))))
                      "no"))))
      (format nil "~a~%bridge up ~a, ~a, canary green ~a ago, watchdog paused: ~a~%~a"
              agent
              (fmt-duration (- (get-universal-time) *bridge-started*))
              (surface-status-line) canary-age pause
            (cmd-recent-incidents))))

(defun cmd-restart ()
  (if (cmd-cd-recent "restart" 120)
      "restart was just requested; cooldown is 2 min"
      (progn
        ;; detached: the killer must survive this bridge's own death
        (ignore-errors
          (sb-ext:run-program "/bin/sh"
                              (list "-c"
                                    "sleep 3; /usr/bin/tmux kill-session -t xmpp-bridge || true")
                              :wait nil :search t))
        "restarting the bridge in 3s; the watchdog will bring it back within ~5 min (the agent session is NOT touched)")))

(defun cmd-compact ()
  (cond ((cmd-cd-recent "compact" 300)
         "compaction was just requested; cooldown is 5 min")
        (t
         (let* ((raw (cmd-status-raw))
                (state (and raw (cmd-sexp-field raw "STATE")))
                (session (or (and raw (cmd-sexp-field raw "SESSION"))
                             (unless (string= *al-session-id* "auto") *al-session-id*))))
           (cond ((null raw) "cannot compact: agent status unavailable")
                 ((null session) "cannot compact: no session resolved")
                 ((and state (not (string-equal state ":IDLE")))
                  (format nil "agent is ~a; /compact only works while idle" state))
                 (t
                  (run-capture
                   (list *al-bin* "localgroup" "tell" session "(compact)") 30)
                  "compaction requested; /status shows the ctx meter drop when it lands"))))))

(defun cmd-canary ()
  (if (cmd-cd-recent "canary" 600)
      "canary was just triggered; cooldown is 10 min"
      (progn
        ;; the watchdog's cadence mark: gone => canary runs next cycle
        (ignore-errors (delete-file (home-path ".cache/saguaro-canary")))
        "canary queued - the next watchdog cycle (within ~5 min) runs a full round trip; green in watchdog.log, or a page on failure")))

(defun cmd-pause (args)
  (cond ((or (string= args "off") (string= args "0"))
         (ignore-errors (delete-file *pause-path*))
         "watchdog pause lifted (auto-repair and pages back on)")
        ((plusp (length args))
         (let ((n (parse-integer args :junk-allowed t)))
           (if (and n (plusp n) (<= n 72))
               (progn
                 (pause-write (* n 3600))
                 (format nil "watchdog paused for ~ah - auto-repair and pages off; these commands keep working. /pause off to lift." n))
               "usage: /pause <1-72 hours> | /pause off")))
        (t
         (let ((exp (watchdog-pause-expiry)))
           (if exp
               (format nil "watchdog paused, ~a left. /pause off to lift"
                       (fmt-duration (- exp (get-universal-time))))
               "watchdog is not paused. usage: /pause <1-72 hours> | /pause off")))))

(defun handle-command (peer body)
  (let* ((line (trim body))
         (sp (position #\Space line))
         (name (string-downcase (subseq line 0 (or sp (length line)))))
         (args (if sp (trim (subseq line (1+ sp))) "")))
    (log-line "COMMAND from ~a: ~a" peer (subseq line 0 (min 100 (length line))))
    (deliver-notice peer *default-surface*
                    (cond ((string= name "/ping") (cmd-ping))
                          ((string= name "/help") (cmd-help))
                          ((string= name "/status") (cmd-status))
                          ((string= name "/restart") (cmd-restart))
                          ((string= name "/compact") (cmd-compact))
                          ((string= name "/canary") (cmd-canary))
                          ((string= name "/pause") (cmd-pause args))
                          (t (format nil "unknown command ~a - /help lists the local commands; resend without the leading / to talk to the agent" name))))))

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
  (let ((send (surface-property surface :sender)))
    (cond ((null send)
           (log-line "no sender registered for surface ~a; notice dropped" surface)
           nil)
          (t (handler-case (progn (funcall send peer text) t)
               (error (e) (log-line "notice to ~a failed: ~a" peer e) nil))))))

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
            (surface (or (getf (cdr task) :surface) *default-surface*))
            (text (format nil "background job finished: ~a~%~a"
                          (task-headline form) (task-body form))))
        (log-line "child job ~a finished -> ~a" child peer)
        (queue-notice peer surface text)
        (log-line "queued child job notice ~a to ~a" child peer)
        (setf (getf (cdr task) :delivered) t)
        (save-state)))))


;;; ---------------------------------------------------------------------
;;; notice digest: a fan-out must not become N instant messages
;;; ---------------------------------------------------------------------
;; 2026-10-30: a SWARM fan-out of ~25 children, most of which died within
;; five seconds, produced 25 private messages in three seconds. Buffer
;; finished-job notices and deliver one digest per (peer, surface).
(defparameter *notice-digest* nil)        ; list of (peer surface text), newest first
(defparameter *notice-digest-since* nil)
(defparameter *notice-digest-window* 45)  ; seconds a lone notice may wait
(defparameter *notice-digest-max* 8)      ; flush early at this many
(defparameter *notice-digest-chars* 6000) ; hard cap on one digest body

(defun queue-notice (peer surface text)
  (when (null *notice-digest*) (setf *notice-digest-since* (now)))
  (push (list peer surface text) *notice-digest*)
  (when (>= (length *notice-digest*) *notice-digest-max*)
    (flush-notices)))

(defun flush-notices ()
  (when *notice-digest*
    (let ((batch (nreverse *notice-digest*)))
      (setf *notice-digest* nil *notice-digest-since* nil)
      (let ((groups ()))
        (dolist (item batch)
          (let* ((key (list (first item) (second item)))
                 (cell (assoc key groups :test #'equal)))
            (if cell
                (setf (cdr cell) (append (cdr cell) (list (third item))))
                (push (cons key (list (third item))) groups))))
        (dolist (cell groups)
          (let* ((key (car cell))
                 (texts (cdr cell))
                 (peer (first key))
                 (surface (second key))
                 (header (if (= (length texts) 1)
                             "background job finished:"
                             (format nil "~d background jobs finished:"
                                     (length texts))))
                 (body (format nil "~{~a~^~%~}" texts)))
            (when (> (length body) *notice-digest-chars*)
              (setf body (concatenate 'string
                                      (subseq body 0 *notice-digest-chars*)
                                      "...[truncated]")))
            (let ((text (format nil "~a~%~a" header body)))
              (log-line "notice digest: ~d job(s) -> ~a" (length texts) peer)
              (unless (deliver-notice peer surface text)
                (park-pending peer surface text)))))))))

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
                         (or (and *turn* (getf *turn* :surface)) *default-surface*)
                         nil)
          (save-state)
          (log-line "tracking child job ~a" child)))
      (dolist (child (child-dirs dir))
        (announce-task child)))))

