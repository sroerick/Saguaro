;;;; bridge.lisp -- the saguaro bridge: entry point and module manifest.
;;;;
;;;; Zero-dependency sbcl --script, same house pattern as glochid.lisp:
;;;;   - no quicklisp; SBCL contribs + subprocesses only
;;;;   - TLS via /usr/bin/openssl s_client -starttls xmpp (lib/xmpp.lisp)
;;;;   - HTTP via curl (lib/core.lisp and the adapters)
;;;;
;;;; Everything else lives in lib/, one library per concern:
;;;;
;;;;   lib/core.lisp         paths, config, logging, subprocess, JSON, base64,
;;;;                         the durable state file
;;;;   lib/autolith.lisp     conversation records, the turn engine, reply
;;;;                         policy, the surface registry, owner commands,
;;;;                         task and notice delivery
;;;;   lib/xmpp.lisp         XMPP transport, :xmpp-private and :xmpp-group
;;;;   lib/pricklypear.lisp  habitat DMs, :pp-dm
;;;;   lib/tuna.lisp         the tuna inbox lane, :tuna-inbox
;;;;   lib/zulip.lisp        Zulip streams and DMs, :zulip
;;;;   lib/bridge.lisp       start-up, the main loop, the picker watcher
;;;;
;;;; A module only depends on the ones listed before it; each is also its own
;;;; ASDF system (saguaro-core, saguaro-xmpp, ...), see saguaro.asd.
;;;;
;;;; External contracts kept from bridge.py (watchdog.py / canary.py /
;;;; start-sessions.sh keep working):
;;;;   - tmux session "xmpp-bridge"; log at harness/bridge.log
;;;;   - turn-in-flight marker  ~/.cache/saguaro-turn-active
;;;;   - config in harness/config.toml ([bridge] [autolith] [pp] ...)
;;;;
;;;; Run:  sbcl --script bridge.lisp
;;;; As a library:  SAGUARO_NO_MAIN=1, then (load "bridge.lisp"), then call
;;;; SG.XMPP / SG.PP / SG.AUTOLITH directly, which is what say.lisp does.

(in-package :cl-user)

#+sbcl (eval-when (:compile-toplevel :load-toplevel :execute)
         (require :sb-posix))

(defparameter *bridge-modules* '("core" "autolith" "channel" "xmpp" "pricklypear" "tuna" "zulip" "bridge")
  "Load order: each name is lib/NAME.lisp and may use everything before it.")

(defun bridge-dir ()
  "Directory holding this file. say.lisp and the boot scripts load the bridge by
path, so nothing here may depend on the current directory."
  (let* ((path (or *load-truename* *default-pathname-defaults*))
         (name (namestring path))
         (slash (position #\/ name :from-end t)))
    (if slash (subseq name 0 (1+ slash)) (namestring *default-pathname-defaults*))))

(defun load-bridge-modules (&optional (dir (bridge-dir)))
  (dolist (name *bridge-modules*)
    (let ((file (concatenate 'string dir "lib/" name ".lisp")))
      (unless (probe-file file)
        (error "bridge module ~a is missing (~a)" name file))
      (load file))))

(load-bridge-modules)

(unless (sg.core:getenv* "SAGUARO_NO_MAIN")
  (handler-case (sg.bridge:main)
    (serious-condition (e) (sg.bridge:fatal-exit e)))
  ;; main should never return; if it does, say so instead of dying silently
  (sg.core:log-line "FATAL: main returned without error")
  (sb-ext:exit :code 1))

;;; ---------------------------------------------------------------------
;;; module contract
;;;
;;; Each adapter fills in one surface keyword with SG.AUTOLITH:REGISTER-SURFACE:
;;;
;;;   :sender      (lambda (peer text))   deliver a finished reply
;;;   :typing      (lambda (peer state))  refresh chat state, optional
;;;   :policy      the configured reply policy string, stream or consolidate
;;;   :label       what a consolidated prompt calls this surface
;;;   :private-p   t for a 1:1 surface
;;;
;;; The adapter also owns its own poller and is started from lib/bridge.lisp.
;;; A new transport means one module, one registration and one start-up call;
;;; nothing in lib/autolith.lisp changes.
;;; ---------------------------------------------------------------------
