;;;; split_check.lisp -- compile and load every bridge module in order and
;;;; report every unresolved name.
;;;;
;;;; This is the regression check for the module split. A symbol that moved to
;;;; another package without an export shows up here as an undefined variable or
;;;; function in exactly one place. Exit status is the number of unresolved
;;;; names, so it can gate a commit.
;;;;
;;;;   sbcl --script harness/dev/split_check.lisp

(require :sb-posix)

(defpackage :saguaro-split-check (:use :cl))
(in-package :saguaro-split-check)

(defparameter *lib-dir*
  (let* ((here (or *load-truename* *default-pathname-defaults*))
         (name (namestring here))
         (slash (position #\/ name :from-end t)))
    (concatenate 'string (subseq name 0 (1+ slash)) "../lib/")))

;; The bridge reads its config when it loads. Point it at the shipped example so
;; this check does not depend on a machine-local config.toml, and so *harness-dir*
;; resolves next to it.
(sb-posix:setenv "BRIDGE_CONFIG"
                 (concatenate 'string *lib-dir* "../config.example.toml")
                 1)

(defparameter *module-list* '("core" "autolith" "xmpp" "pricklypear" "tuna" "zulip" "bridge"))

(defparameter *interesting* '("undefined" "not found" "does not exist" "unknown variable"))

(defun interesting-p (text)
  (some (lambda (needle) (search needle text)) *interesting*))

(defun compile-module (name)
  "Compile lib/NAME.lisp. Returns (values fasl-path unresolved-warning-texts)."
  (let ((src (concatenate 'string *lib-dir* name ".lisp"))
        (fasl (concatenate 'string "/tmp/saguaro-split-" name ".fasl"))
        (warnings '()))
    (handler-bind ((warning (lambda (c)
                              (let ((text (princ-to-string c)))
                                (when (interesting-p text) (push text warnings)))
                              (muffle-warning c))))
      (compile-file src :output-file fasl :verbose nil :print nil))
    (values fasl (nreverse warnings))))

(defun check ()
  (let ((total 0))
    (dolist (name *module-list*)
      (multiple-value-bind (fasl warnings) (compile-module name)
        (format t "~&~a: ~d unresolved~%" name (length warnings))
        (dolist (w warnings)
          (incf total)
          (format t "  ~a: ~a~%" name (substitute #\Space #\Newline w)))
        (when fasl (load fasl))))
    (format t "~&total unresolved: ~d~%" total)
    total))

(let ((unresolved (check)))
  (finish-output)
  (sb-ext:exit :code (min 100 unresolved)))
