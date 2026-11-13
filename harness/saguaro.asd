;;;; saguaro.asd -- ASDF systems for the bridge modules.
;;;;
;;;; The shipped bridge does not use these: harness/bridge.lisp loads lib/*.lisp
;;;; in order with plain LOAD, which keeps the zero-dependency `sbcl --script`
;;;; contract (no quicklisp, no ASDF at runtime). The systems exist so a module
;;;; can be loaded, tested or edited on its own, and so the dependency direction
;;;; is written down once:
;;;;
;;;;   (asdf:load-asd "/path/to/harness/saguaro.asd")
;;;;   (asdf:load-system "saguaro-xmpp")
;;;;
;;;; Dependency direction: core <- autolith <- adapters <- bridge.

(defsystem "saguaro-core"
  :description "Paths, TOML config, logging, subprocess capture, JSON, base64, durable state."
  :license "MIT"
  :pathname "lib"
  :depends-on ("sb-posix")
  :components ((:file "core")))

(defsystem "saguaro-autolith"
  :description "Conversation records, the turn engine, reply policy, the surface registry, owner commands, task notices."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-core")
  :components ((:file "autolith")))

(defsystem "saguaro-channel"n  :description "One channel per surface and peer: registry, world-server channels, per-channel turn queues."n  :license "MIT"n  :pathname "lib"n  :depends-on ("saguaro-autolith")n  :components ((:file "channel")))nn(defsystem "saguaro-xmpp"
  :description "XMPP transport: tunnel, stream, SASL, bind, MUC, stanza dispatch, :xmpp-private and :xmpp-group."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-autolith")
  :components ((:file "xmpp")))

(defsystem "saguaro-pricklypear"
  :description "Pricklypear habitat surface (:pp-dm): eval client, send with retry, cursors, poller."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-autolith")
  :components ((:file "pricklypear")))

(defsystem "saguaro-tuna"
  :description "The tuna inbox lane (:tuna-inbox)."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-autolith")
  :components ((:file "tuna")))

(defsystem "saguaro-zulip"
  :description "The Zulip surface (:zulip): events queue, should-I-respond policy, sender."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-autolith")
  :components ((:file "zulip")))

(defsystem "saguaro-bridge"
  :description "Start-up, the main loop and the picker watcher: the only module that knows which adapters exist."
  :license "MIT"
  :pathname "lib"
  :depends-on ("saguaro-channel" "saguaro-xmpp" "saguaro-pricklypear" "saguaro-tuna" "saguaro-zulip")
  :components ((:file "bridge")))

(defsystem "saguaro"
  :description "Every bridge module."
  :license "MIT"
  :depends-on ("saguaro-bridge"))
