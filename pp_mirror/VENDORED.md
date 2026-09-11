Vendored from the Pricklypear repo (nopalito/ subtree), ISC License,
Copyright (c) 2026 Roerick Sweeney.

  nopalito.lisp     portable Nopales-subset interpreter + PP memory store
  graft-drain.lisp  cron drain: local graft queue -> Pricklypear

Source of truth: the Pricklypear repo. This copy is a synced snapshot.

Local edits vs upstream (re-apply when re-syncing):
  1. load-env default path: $HOME-relative instead of the operator's
     home directory.
  2. graft-drain: $NOPALES_HOME is required; no hard-coded fallback.
