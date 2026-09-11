;;;; nopalito.lisp -- Gregor's Pricklypear dual-home layer.
;;;; A portable Nopales subset interpreter with local/remote backends, plus
;;;; the PP-backed store for Autolith persistent memories.
;;;;
;;;; Backends:
;;;;   :remote  whole-form eval on the live PP image over /api/eval (the
;;;;            reference implementation: durable rows, RLS, history).
;;;;   :local   in-memory emulation of the prim subset (immediate, offline).
;;;;   :both    run both, compare, record divergence -- the feedback loop
;;;;            that grows local fidelity prim by prim.
;;;;
;;;; Zero deps beyond SBCL + curl. Memory type: gregor-memory rows in the
;;;; member-gated cactus-ops space (owner gregor), one row per active
;;;; memory keyed by the Autolith stable id in field "mid".

(defpackage :nopalito
  (:use :cl)
  (:export
   #:*pp-url* #:*pp-token* #:*pp-timeout* #:load-env
   #:*backend* #:*divergences* #:remote-error
   #:pp-eval #:pp-eval-ok
   #:nopales-read #:nopales-eval #:serialize
   #:run #:run-string #:check
   #:local-reset #:*local-store* #:*local-author*
   #:json-decode #:json-encode-string #:json-object
   #:cl-literal
   ;; memory store
   #:*memory-type* #:*memory-space*
   #:memory-record->fields #:fields->memory-record
 #:pp-memory-delete #:pp-memory-pull
 #:pp-memory-ensure-space
 ;; graft queue (local-first)
 #:*graft-dir* #:*graft-log-path* #:*graft-state-path*
 #:graft-record #:graft-upsert #:graft-delete #:graft-load
 #:graft-drain #:graft-status #:graft-pending-count #:graft-compact
 #:graft-rebuild))

(in-package :nopalito)

;;;; -- tiny string helpers

(defun str-prefix-p (prefix string)
  "Return non-NIL when STRING starts with PREFIX."
  (let ((n (length prefix)))
    (and (>= (length string) n)
         (string= string prefix :end1 n))))

(defun trim (string)
  (string-trim '(#\Space #\Tab #\Return #\Newline) string))

;;;; -- minimal JSON

(defun json-encode-string (string)
  "Encode one STRING as a JSON string literal."
  (with-output-to-string (out)
    (write-char #\" out)
    (loop for ch across string
          do (cond ((eql ch #\") (write-string "\\\"" out))
                   ((eql ch #\\) (write-string "\\\\" out))
                   ((eql ch #\Newline) (write-string "\\n" out))
                   ((eql ch #\Return) (write-string "\\r" out))
                   ((eql ch #\Tab) (write-string "\\t" out))
                   ((< (char-code ch) 32)
                    (format out "\\u~4,'0x" (char-code ch)))
                   (t (write-char ch out))))
    (write-char #\" out)))

(defun json-object (alist)
  "Encode an ALIST of (key . string-or-int) as a JSON object."
  (with-output-to-string (out)
    (write-char #\{ out)
    (let ((firstp t))
      (dolist (pair alist)
        (unless firstp (write-char #\, out))
        (setf firstp nil)
        (write-string (json-encode-string (car pair)) out)
        (write-char #\: out)
        (write-string
         (typecase (cdr pair)
           (integer (princ-to-string (cdr pair)))
           (t (json-encode-string (princ-to-string (cdr pair)))))
         out)))
    (write-char #\} out)))

(defun json-decode (text)
  "Decode JSON TEXT into CL data: objects as alists keyed by strings,
arrays as lists, true/false as :true/:false, null as :nil."
  (let ((pos 0)
        (len (length text)))
    (labels ((ws ()
               (loop while (and (< pos len)
                                (member (char text pos)
                                        '(#\Space #\Tab #\Newline #\Return)))
                     do (incf pos)))
             (peek () (and (< pos len) (char text pos)))
             (take () (let ((ch (char text pos))) (incf pos) ch))
             (value ()
               (ws)
               (let ((ch (peek)))
                 (cond ((null ch) (error "json: unexpected end"))
                       ((eql ch #\{) (object))
                       ((eql ch #\[) (array))
                        ((eql ch #\") (json-string))
                       ((eql ch #\t) (lit "true" :true))
                       ((eql ch #\f) (lit "false" :false))
                       ((eql ch #\n) (lit "null" :nil))
                       (t (number)))))
             (lit (word result)
               (if (and (<= (+ pos (length word)) len)
                        (string= text word :start1 pos :end1 (+ pos (length word))))
                   (progn (incf pos (length word)) result)
                   (error "json: bad literal at ~d" pos)))
             (object ()
               (take)                             ; {
               (let ((alist ()))
                 (ws)
                 (when (eql (peek) #\}) (take) (return-from object alist))
                 (loop
                   (ws)
                   (unless (eql (peek) #\") (error "json: expected key"))
                    (let ((key (json-string)))
                     (ws)
                     (unless (eql (take) #\:) (error "json: expected :"))
                     (push (cons key (value)) alist))
                   (ws)
                   (let ((ch (take)))
                     (cond ((eql ch #\,) )
                           ((eql ch #\}) (return (nreverse alist)))
                           (t (error "json: bad object")))))))
             (array ()
               (take)                             ; [
               (let ((items ()))
                 (ws)
                 (when (eql (peek) #\]) (take) (return-from array items))
                 (loop
                   (push (value) items)
                   (ws)
                   (let ((ch (take)))
                     (cond ((eql ch #\,) )
                           ((eql ch #\]) (return (nreverse items)))
                           (t (error "json: bad array")))))))
              (json-string ()
               (take)                             ; "
               (with-output-to-string (out)
                 (loop
                   (let ((ch (take)))
                     (cond ((eql ch #\") (return))
                           ((eql ch #\\)
                            (let ((esc (take)))
                              (case esc
                                (#\" (write-char #\" out))
                                (#\\ (write-char #\\ out))
                                (#\/ (write-char #\/ out))
                                (#\b (write-char #\Backspace out))
                                (#\f (write-char #\Page out))
                                (#\n (write-char #\Newline out))
                                (#\r (write-char #\Return out))
                                (#\t (write-char #\Tab out))
                                (#\u
                                 (let ((code (parse-integer text :start pos :end (+ pos 4) :radix 16)))
                                   (incf pos 4)
                                   (write-char (code-char code) out)))
                                (t (error "json: bad escape ~c" esc)))))
                           (t (write-char ch out)))))))
             (number ()
               (let ((start pos)
                     (floatp nil))
                 (loop while (and (< pos len)
                                  (or (digit-char-p (char text pos))
                                      (member (char text pos) '(#\- #\+ #\. #\e #\E))))
                       do (when (member (char text pos) '(#\. #\e #\E)) (setf floatp t))
                          (incf pos))
                 (if floatp
                     (with-input-from-string (s text :start start :end pos) (read s))
                     (parse-integer text :start start :end pos)))))
      (let ((result (value)))
        (ws)
        result))))

;;;; -- PP client (curl, same wire shape as the proven forge-send helper)

(defparameter *pp-url* nil)
(defparameter *pp-token* nil)
(defparameter *pp-timeout* 30)

(defun load-env (&optional (path (merge-pathnames ".config/saguaro/env" (user-homedir-pathname))))
  "Load PP_URL and PP_TOKEN from an env-style file."
  (with-open-file (f path :if-does-not-exist :error)
    (loop for line = (read-line f nil nil)
          while line
          do (cond ((str-prefix-p "PP_URL=" line)
                    (setf *pp-url* (trim (subseq line 7))))
                   ((str-prefix-p "PP_TOKEN=" line)
                    (setf *pp-token* (trim (subseq line 9))))))))

(define-condition remote-error (error)
  ((payload :initarg :payload :reader remote-error-payload))
  (:report (lambda (c s) (format s "pp remote error: ~a" (remote-error-payload c)))))

(defun pp-raw (expr-string)
  "POST EXPR-STRING to /api/eval; return the decoded response object."
  (unless (and *pp-url* *pp-token*) (load-env))
  (let ((body (merge-pathnames
               (format nil ".nopales-body.~d.~d" (get-universal-time) (random (expt 2 30)))
               #P"/tmp/"))
        (out (make-string-output-stream)))
    (with-open-file (f body :direction :output :if-exists :supersede)
      (format f "{\"expr\":~a}" (json-encode-string expr-string)))
    (unwind-protect
         (let ((proc (sb-ext:run-program
                      "/usr/local/bin/curl"
                      (list "-s" "-m" (princ-to-string *pp-timeout*)
                            "-H" "Content-Type: application/json"
                            "-H" (format nil "Authorization: Bearer ~a" *pp-token*)
                            "-d" (concatenate 'string "@" (namestring body))
                            (format nil "~a/api/eval" *pp-url*))
                      :output :stream :error nil :wait nil :search t)))
           (unless proc (error "could not run curl"))
           (unwind-protect
                (progn
                  (loop for line = (read-line (sb-ext:process-output proc) nil nil)
                        while line do (write-line line out))
                  (sb-ext:process-wait proc))
             (ignore-errors (close (sb-ext:process-output proc)))
             (ignore-errors (sb-ext:process-close proc))))
      (ignore-errors (delete-file body)))
    (let ((text (get-output-stream-string out)))
      (unless (> (length text) 0)
        (error 'remote-error :payload "empty response (transport failure?)"))
      (json-decode text))))

(defun pp-eval-ok (expr-string)
  "Evaluate EXPR-STRING on PP; return (values ok value)."
  (let* ((resp (pp-raw expr-string))
         (ok (cdr (assoc "ok" resp :test #'string=))))
    (values (eq ok :true) (cdr (assoc "value" resp :test #'string=)))))

(defun pp-eval (expr-string)
  "Evaluate EXPR-STRING on PP; return the VALUE or signal REMOTE-ERROR."
  (multiple-value-bind (ok value) (pp-eval-ok expr-string)
    (unless ok (error 'remote-error :payload value))
    value))

;;;; -- Nopales reader/printer (CL-compatible subset, lowercase symbols)

(defun nopales-read (string)
  "Read one form from STRING using the CL reader in the NOPALES package."
  (let ((*package* (find-package :nopalito)))
    (with-input-from-string (s string)
      (read s))))

(defun serialize (form)
  "Print FORM back to Nopales source text (lowercase symbols, CL strings)."
  (with-output-to-string (out)
    (labels ((write-form (f)
               (cond ((null f) (write-string "()" out))
                     ((symbolp f)
                      (write-string (string-downcase (symbol-name f)) out))
                     ((stringp f) (format out "~s" f))
                     ((integerp f) (format out "~d" f))
                     ((listp f) (write-char #\( out)
                      (loop for rest on f
                            do (write-form (first rest))
                               (when (rest rest) (write-char #\Space out)))
                      (write-char #\) out))
                     (t (error "cannot serialize ~s" f)))))
      (write-form form))))

;;;; -- local data plane (the emulation)

(defparameter *local-store* (make-hash-table :test 'equal)
  "type name -> hash table id -> fields alist")
(defparameter *local-author* "gregor")
(defparameter *local-spaces* (make-hash-table :test 'equal)
  "space name -> (members admitted-types)")
(defparameter *local-gen* 100)

(defun local-reset ()
  (setf *local-store* (make-hash-table :test 'equal)
        *local-spaces* (make-hash-table :test 'equal)
        *local-gen* 100))

(defun local-rows (type)
  (or (gethash type *local-store*)
      (setf (gethash type *local-store*) (make-hash-table :test 'equal))))

(defun local-uuid ()
  (format nil "~8,'0x-~4,'0x-4~3,'0x-~4,'0x-~12,'0x"
          (random (expt 2 32)) (random (expt 2 16)) (random 4096)
          (logior #x8000 (random (expt 2 15))) (random (expt 2 48))))

(defun coerce-name (x)
  "Field/type names arrive as symbols (via quote) or strings."
  (typecase x
    (symbol (string-downcase (symbol-name x)))
    (string x)
    (t (princ-to-string x))))

(defun coerce-fields (json-string)
  "Decode a fields JSON string into an alist; coerce scalars to strings."
  (let ((decoded (json-decode json-string)))
    (when decoded
      (loop for (key . value) in decoded
            collect (cons key (scalar-string value))))))

(defun scalar-string (value)
  "PP coerces numeric strings to JSON numbers; normalize leaves to strings."
  (typecase value
    (string value)
    (integer (princ-to-string value))
    (float (princ-to-string value))
    ((member :true :false) (if (eq value :true) "true" "false"))
    (t (and value (princ-to-string value)))))

(defun row-matches-p (fields filters)
  (loop for (field . value) in filters
        always (string= (scalar-string (cdr (assoc field fields :test #'string=)))
                        (scalar-string value))))

;;;; -- special forms + prim dispatch

(defparameter *backend* :remote)
(defparameter *divergences* ())

(defun prim-apply-local (name args)
  (case (intern (string-upcase name) :keyword)
    (:create
     (destructuring-bind (type fields-json) args
       (let* ((type (coerce-name type))
              (id (local-uuid)))
         (setf (gethash id (local-rows type)) (coerce-fields fields-json))
         id)))
    (:update
     (destructuring-bind (type id fields-json) args
       (let ((type (coerce-name type))
             (id (coerce-name id)))
         (if (gethash id (local-rows type))
             (progn (setf (gethash id (local-rows type)) (coerce-fields fields-json)) id)
             nil))))
    (:update-field
     (destructuring-bind (type id field value) args
       (let* ((type (coerce-name type))
              (id (coerce-name id))
              (fields (gethash id (local-rows type))))
         (cond ((null fields) nil)
               (t
                (let ((pair (assoc (coerce-name field) fields :test #'string=)))
                  (if pair
                      (setf (cdr pair) (scalar-string value))
                        (setf fields (append fields (list (cons (coerce-name field) (scalar-string value))))
                            (gethash id (local-rows type)) fields)))
                id)))))
    (:delete
     (destructuring-bind (type id) args
       (let ((type (coerce-name type))
             (id (coerce-name id)))
       (if (gethash id (local-rows type))
           (progn (remhash id (local-rows type)) id)
           nil))))
    (:get
     (destructuring-bind (type id) args
       (let ((fields (gethash (coerce-name id) (local-rows (coerce-name type)))))
         (and fields (json-object fields)))))
    (:rows
     (destructuring-bind (type &optional limit) args
       (declare (ignore limit))
       (local-list (coerce-name type) (constantly t))))
    (:find-rows
     (destructuring-bind (type &rest rest) args
       (local-find-rows (coerce-name type) rest nil)))
    (:find-rows-author
     (destructuring-bind (type &rest rest) args
       (loop for (id fields) in (local-find-rows (coerce-name type) rest nil)
             collect (list id *local-author* fields))))
    (:find-row
     (destructuring-bind (type field value) args
       (let ((rows (local-find-rows (coerce-name type)
                                    (list (coerce-name field) value) 1)))
         (if rows
             (json-object (second (first rows)))
             nil))))
    (:find-text
     (destructuring-bind (type field needle &optional limit) args
       (local-find-rows (coerce-name type)
                        (list (coerce-name field) needle) limit
                        (lambda (fields)
                          (search (scalar-string needle)
                                  (scalar-string (cdr (assoc (coerce-name field) fields :test #'string=)))
                                  :test #'char-equal)))))
    (:count
     (destructuring-bind (list) args (length list)))
    (:now (get-universal-time))
    (:now-ms (* 1000 (get-universal-time)))
    (:gen-now (incf *local-gen*))
    (:random-uuid (local-uuid))
    (:list args)
    (:space-exists? (destructuring-bind (name) args (not (null (gethash (coerce-name name) *local-spaces*)))))
    (:space-create
     (destructuring-bind (name &optional flag) args
       (setf (gethash (coerce-name name) *local-spaces*) (list () ()))
       (coerce-name name)))
    (:space-admit
     (destructuring-bind (type space) args
       (push (coerce-name type) (second (gethash (coerce-name space) *local-spaces*)))
       (format nil "type ~a admitted to space ~a" (coerce-name type) (coerce-name space))))
    (:space-list (loop for space being the hash-keys of *local-spaces* collect space))
    (:space-members
     (destructuring-bind (space) args
       (or (first (gethash (coerce-name space) *local-spaces*)) ())))
    (:data-history
     (destructuring-bind (type id) args
       (declare (ignore type))
       ()))
    (t (error "local backend: unknown prim ~a" name))))

(defun local-list (type predicate)
  (loop for id being the hash-keys of (local-rows type)
          using (hash-value fields)
        when (funcall predicate fields)
          collect (list id fields)))

(defun local-find-rows (type rest &optional limit predicate)
  "REST is (f v ... [limit] [sort]) like the prim."
  (let ((filters ())
        (limit2 (or limit 500)))
    (loop for (a b) on rest by #'cddr
          do (cond ((and (null b) (integerp a)) (setf limit2 a))
                   ((null b) )
                   (t (push (cons (coerce-name a) b) filters))))
    (setf filters (nreverse filters))
    (let ((rows
            (loop for (id fields) in (local-list type (constantly t))
                  when (and (if predicate
                                (funcall predicate fields)
                                (row-matches-p fields filters))
                            (> limit2 0))
                    collect (list id fields)
                    do (decf limit2))))
      rows)))

(defun nopales-eval (form &optional (backend *backend*))
  "Evaluate FORM under BACKEND."
  (ecase backend
    (:remote (pp-eval (serialize form)))
    (:local (local-eval form))
    (:both (run-both form))))

(defun local-eval (form)
  (cond ((or (stringp form) (integerp form) (member form '(nil t))) form)
        ((symbolp form) (error "unbound symbol ~a" form))
        ((listp form)
         (let ((head (first form)))
           (cond ((eq head 'quote) (second form))
                 ((eq head 'if) (if (local-eval (second form))
                                    (local-eval (third form))
                                    (local-eval (fourth form))))
                 ((eq head 'seq) (progn (mapc #'local-eval (butlast (rest form)))
                                        (local-eval (first (last form)))))
                 ((symbolp head)
                  (prim-apply-local (string-downcase (symbol-name head))
                                    (mapcar #'local-eval (rest form))))
                 (t (error "cannot apply ~s" head))))
         )
        (t (error "cannot eval ~s" form))))

(defun run-string (expr-string &optional (backend *backend*))
  (nopales-eval (nopales-read expr-string) backend))

(defun run (form &optional (backend *backend*))
  (nopales-eval form backend))

(defun normalize (value)
  "Normalize a decoded value tree for comparison."
  (cond ((eq value :true) t)
        ((eq value :false) nil)
        ((eq value :nil) nil)
        ((stringp value) value)
        ((numberp value) (princ-to-string value))
        ((consp value)
         (if (and (consp (first value)) (stringp (car (first value))))
             (mapcar (lambda (p) (cons (car p) (normalize (cdr p)))) value)
             (mapcar #'normalize value)))
        (t value)))

(defun run-both (form)
  "Run FORM on both backends; return the remote value and note divergence."
  (let* ((remote (normalize (pp-eval (serialize form))))
         (local (handler-case (normalize (local-eval form))
                  (error (e) (list :local-error (princ-to-string e))))))
    (unless (equal remote local)
      (push (list (serialize form) remote local) *divergences*))
    remote))

;;;; -- gregor-memory store

(defparameter *memory-type* "gregor-memory")
(defparameter *memory-space* "cactus-ops")

(defun memory-record->fields (record)
  "Autolith (:memory ...) record plist -> PP fields alist (all strings)."
  (let ((props (cdr record)))
    (list (cons "mid" (getf props :id))
          (cons "ver" (princ-to-string (or (getf props :version) 1)))
          (cons "cat" (princ-to-string (getf props :created-at)))
          (cons "uat" (princ-to-string (getf props :updated-at)))
          (cons "scope" (string-downcase (princ-to-string (getf props :scope))))
          (cons "ws" (or (getf props :workspace) ""))
          (cons "title" (getf props :title))
          (cons "content" (getf props :content))
            (cons "tags" (json-encode (or (getf props :tags) ())))
          (cons "src" (or (getf props :source-conversation) "")))))

(defun json-encode (value)
  "Encode a small CL value (list of strings, strings, numbers) as JSON."
  (typecase value
    (null "[]")
    (cons (format nil "[~{~a~^,~}]"
                  (mapcar (lambda (v)
                            (typecase v
                              (string (json-encode-string v))
                              (t (princ-to-string v))))
                          value)))
    (string (json-encode-string value))
    (t (princ-to-string value))))

(defun fields->memory-record (fields)
  "PP fields alist -> Autolith (:memory ...) record plist shape."
   (labels ((f (name) (scalar-string (cdr (assoc name fields :test #'string=))))
         (int (name) (let ((v (f name))) (and v (ignore-errors (parse-integer v))))))
    (list :memory
          :version (or (int "ver") 1)
          :id (f "mid")
          :created-at (or (int "cat") 0)
          :updated-at (or (int "uat") 0)
          :scope (intern (string-upcase (or (f "scope") "workspace")) :keyword)
          :workspace (let ((ws (f "ws"))) (and (> (length ws) 0) ws))
          :title (f "title")
          :content (f "content")
          :tags (let ((raw (f "tags")))
                  (if (and raw (> (length raw) 0))
                      (mapcar #'scalar-string (json-decode raw))
                      ()))
          :source-conversation (let ((s (f "src"))) (and (> (length s) 0) s)))))

(defvar *memory-space-ready* nil)

(defun pp-memory-ensure-space ()
  "Admit the memory type into cactus-ops once per process."
  (unless *memory-space-ready*
    (ignore-errors
     (pp-eval (format nil "(space-admit ~s ~s)" *memory-type* *memory-space*)))
    (setf *memory-space-ready* t)))

(defun pp-memory-create (record)
  (pp-memory-ensure-space)
  (pp-eval (format nil "(create (quote ~a) ~s)"
                   *memory-type*
                   (json-object (memory-record->fields record)))))

(defun pp-memory-update (id record)
  (pp-memory-ensure-space)
  (pp-eval (format nil "(update (quote ~a) ~s ~s)"
                   *memory-type* id
                   (json-object (memory-record->fields record)))))

(defun pp-memory-upsert (record)
  "Create or replace the PP row for RECORD (keyed by :id in field mid)."
  (let* ((mid (getf (cdr record) :id))
         (rows (pp-eval (format nil "(find-rows (quote ~a) (quote mid) ~s)"
                                *memory-type* mid)))
         (existing (first rows)))
    (if existing
        (pp-memory-update (first existing) record)
        (pp-memory-create record))))

(defun pp-memory-delete (mid)
  (let ((rows (pp-eval (format nil "(find-rows (quote ~a) (quote mid) ~s)"
                               *memory-type* mid))))
    (dolist (row rows)
      (pp-eval (format nil "(delete (quote ~a) ~s)" *memory-type* (first row))))
    (length rows)))

(defun pp-memory-pull (&optional (type *memory-type*))
  "All memory rows on PP as (:pp-id ID :record RECORD) entries."
  (mapcar (lambda (row)
            (list :pp-id (first row)
                  :record (fields->memory-record (second row))))
          (pp-eval (format nil "(rows (quote ~a) 500)" type))))
;;;; -- graft queue (local-first)
;;;;
;;;; The local store is primary: Autolith memory writes eval locally and
;;;; append to an on-disk graft log. A separate drain replays unsynced
;;;; entries to PP in batched evals, idempotent by mid. Nothing on the
;;;; write path touches the network; PP unavailability only delays the
;;;; drain. Log format: one (prin1)ed plist per line, read back with the
;;;; CL reader; a torn final line is skipped and lost (accept: the local
;;;; Autolith memory log remains the source of truth and can re-graft).

(defparameter *graft-dir*
  (let ((env (sb-ext:posix-getenv "NOPALES_DATA")))
    (if (and env (> (length env) 0))
        (pathname (if (char= (char env (1- (length env))) #\/)
                      env
                      (concatenate 'string env "/")))
        (merge-pathnames (concatenate 'string (or (sb-ext:posix-getenv "HOME") (namestring (user-homedir-pathname))) "/.local/share/nopalito/"))))
  "Graft queue directory; override with $NOPALES_DATA for portable installs.")
(defparameter *graft-log-path* (merge-pathnames "graft.log" *graft-dir*))
(defparameter *graft-state-path* (merge-pathnames "graft-state.sexp" *graft-dir*))
(defparameter *graft-chunk-bytes* 32000
  "Max eval string size per drain chunk; PP eval cap is 64 KiB.")
(defvar *graft-seq* 0)
(defvar *graft-watermark* 0)
(defvar *graft-loaded* nil)

(defun graft-read-log ()
  (when (probe-file *graft-log-path*)
    (with-open-file (f *graft-log-path* :if-does-not-exist nil)
      (when f
        (loop for form = (read f nil nil)
              while form collect form)))))

(defun graft-save-state ()
  (with-open-file (f *graft-state-path* :direction :output :if-exists :supersede)
    (prin1 (list :seq *graft-seq* :watermark *graft-watermark*) f))
  nil)

(defun graft-load ()
  "Fold the graft log into the local store; restore seq and watermark."
  (ensure-directories-exist *graft-dir*)
  (when (probe-file *graft-state-path*)
    (with-open-file (f *graft-state-path*)
      (let ((state (read f nil nil)))
        (when state
          (setf *graft-seq* (max *graft-seq* (or (getf state :seq) 0))
                *graft-watermark* (max *graft-watermark* (or (getf state :watermark) 0)))))))
  (dolist (entry (graft-read-log))
    (graft-apply-local entry)
    (setf *graft-seq* (max *graft-seq* (or (getf entry :seq) 0))))
  (setf *graft-loaded* t)
  nil)

(defun graft-apply-local (entry)
  "Apply one graft entry to the in-memory local store. No I/O."
  (let ((rows (local-rows *memory-type*))
        (mid (getf entry :mid)))
    (if (eq (getf entry :op) :delete)
        (remhash mid rows)
        (setf (gethash mid rows)
              (memory-record->fields (getf entry :record))))))

(defun graft-append (entry)
  "Apply ENTRY locally, assign the next sequence number, append to the log."
  (unless *graft-loaded* (graft-load))
  (graft-apply-local entry)
  (incf *graft-seq*)
  (setf (getf entry :seq) *graft-seq*)
  (with-open-file (f *graft-log-path*
                     :direction :output :if-exists :append :if-does-not-exist :create)
    (prin1 entry f)
    (terpri f))
  *graft-seq*)

(defun graft-upsert (record)
  "Queue an Autolith :memory RECORD for PP and apply it locally."
  (graft-append (list :op :upsert :mid (getf (rest record) :id)
                      :record record :ts (get-universal-time))))

(defun graft-delete (mid)
  "Queue deletion of memory MID from PP and apply it locally."
  (graft-append (list :op :delete :mid mid :ts (get-universal-time))))

(defun graft-record (record)
  "Autolith hook entry point: dispatch one record onto the graft queue."
  (cond ((eq (first record) :memory)
         (graft-upsert record))
        ((eq (first record) :memory-forgotten)
         (graft-delete (getf (rest record) :id)))
        (t (error "graft-record: unknown record kind ~s" (first record)))))

(defun graft-status ()
  (unless *graft-loaded* (graft-load))
  (list :local-rows (hash-table-count (local-rows *memory-type*))
        :graft-seq *graft-seq*
        :watermark *graft-watermark*
        :pending (max 0 (- *graft-seq* *graft-watermark*))))

(defun graft-chunk-exprs (entries id-map)
  "Build batched (seq ...) eval strings for ENTRIES given MID->PP-ID MAP."
  (let ((chunks ()) (current "(seq") (size 5))
    (labels ((flush ()
               (unless (string= current "(seq")
                 (push (concatenate 'string current " )") chunks)
                 (setf current "(seq" size 5)))
             (emit (form-text)
               (let ((len (length form-text)))
                 (when (> (+ size len) *graft-chunk-bytes*) (flush))
                 (setf current (concatenate 'string current " " form-text)
                       size (+ size len 1)))))
      (dolist (entry entries)
        (let* ((mid (getf entry :mid))
               (pp-id (cdr (assoc mid id-map :test #'string=))))
          (cond ((eq (getf entry :op) :delete)
                 (when pp-id
                   (emit (format nil "(delete (quote ~a) ~s)" *memory-type* pp-id))))
                (t
                 (let ((fields (json-object (memory-record->fields (getf entry :record)))))
                   (if pp-id
                       (emit (format nil "(update (quote ~a) ~s ~s)"
                                     *memory-type* pp-id fields))
                       (emit (format nil "(create (quote ~a) ~s)"
                                     *memory-type* fields))))))))
      (flush))
    (nreverse chunks)))

(defun graft-drain ()
  "Replay unsynced graft entries to PP in batched evals. Idempotent by mid:
advances the watermark only when every chunk succeeds, so a failure simply
replays next time."
  (unless *graft-loaded* (graft-load))
  (let* ((collected (loop for entry in (graft-read-log)
                          when (> (getf entry :seq 0) *graft-watermark*)
                            collect entry))
         ;; fold to the latest entry per mid so several queued writes of
         ;; one memory produce exactly one remote op per drain
         (latest (make-hash-table :test 'equal))
         (top-seq 0))
    (dolist (entry collected)
      (setf (gethash (getf entry :mid) latest) entry
            top-seq (max top-seq (getf entry :seq 0))))
    (let ((pending (loop for entry being the hash-values of latest collect entry)))
      (if (null pending)
          (list :drained 0 :watermark *graft-watermark*)
          (progn
            (pp-memory-ensure-space)
            (let* ((remote-rows (pp-eval (format nil "(rows (quote ~a) 500)" *memory-type*)))
                   (id-map (loop for row in remote-rows
                                 for fields = (second row)
                                 for mid = (and fields (cdr (assoc "mid" fields :test #'string=)))
                                 when mid collect (cons mid (first row))))
                   (chunks (graft-chunk-exprs pending id-map)))
              (dolist (expr chunks) (pp-eval expr)))
            (setf *graft-watermark* top-seq)
            (graft-save-state)
            (when (> (length (graft-read-log)) 500) (graft-compact))
            (list :drained (length pending) :watermark *graft-watermark*))))))

(defun graft-compact ()
  "Rewrite the graft log: latest upsert per mid for drained entries, plus the
undrained tail. Drained deletes simply drop."
  (unless *graft-loaded* (graft-load))
  (let* ((entries (graft-read-log))
         (latest (make-hash-table :test 'equal))
         (tail ()))
    (dolist (entry entries)
      (if (> (getf entry :seq 0) *graft-watermark*)
          (push entry tail)
          (setf (gethash (getf entry :mid) latest) entry)))
    (let ((folded (loop for entry being the hash-values of latest
                        when (eq (getf entry :op) :upsert) collect entry)))
      (with-open-file (f *graft-log-path* :direction :output :if-exists :supersede)
        (dolist (entry (append (nreverse folded) (nreverse tail)))
          (prin1 entry f)
          (terpri f)))
      (list :folded (length folded) :tail (length tail)))))

(defun graft-rebuild ()
  "Re-queue an upsert for every memory currently in the local store
(disaster recovery / full push); drain replays them idempotently."
  (unless *graft-loaded* (graft-load))
  (let ((count 0))
    (maphash (lambda (mid fields)
               (declare (ignore mid))
               (graft-upsert (fields->memory-record fields))
               (incf count))
             (local-rows *memory-type*))
    (list :queued count)))
