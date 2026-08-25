# frozen_string_literal: true

module Agent
  module Sessions
        # The one way this gem opens a SQLite store: read-only, URI-escaped, with a
        # bounded retry against a live writer's lock. Extracted from the opencode
        # adapter when the opencode reader became its second caller — two copies of
        # escape_uri_path would drift, and the bug it guards is subtle enough that a
        # drifted copy would look correct in review.
        #
        # What differs between callers stays with them: the adapter raises
        # UnreadableStore on a query failure because a vanished database means no
        # sessions at all, while a reader warns and yields nothing because one
        # unreadable session must not take down a sweep (Layer 3 rule 2). This
        # module only opens; it never decides what a failure means.
        module Sqlite
          module_function

          # No immutable=1: it tells SQLite to trust that the file will never change
          # and skip locking AND the WAL entirely — against a live, WAL-mode
          # opencode.db that means silently missing every committed-but-not-yet-
          # checkpointed session. Opening a WAL db even read-only touches its -shm
          # and -wal sidecars (SQLite's own reader bookkeeping, confirmed directly);
          # the recorded sessions themselves are never written.
          #
          # busy_timeout gives SQLite up to 5s to retry internally against a lock
          # held by the agent's own live writer. A WAL writer's lock is normally held
          # only for the instant of a commit, so a lock that has not cleared within
          # 5s is a stuck process, not ordinary contention.
          def open_readonly(path)
            db = SQLite3::Database.new(
              "file:#{escape_uri_path(path)}?mode=ro",
              flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI
            )
            db.busy_timeout = 5_000
            db
          end

          # IMPORTANT, caught in review: SQLite's URI parser gives `%`, `#` and `?`
          # syntactic meaning, and the path was being interpolated raw. `#` starts a
          # fragment (silently truncating the path there); `?` starts the query
          # string, colliding with the `?mode=ro` open_readonly appends. The worst
          # case, confirmed directly: a path segment that merely CONTAINS a
          # valid-looking percent-escape — a directory literally named "a%23b" —
          # gets that escape DECODED by the URI parser into a different path
          # ("a#b"), so a second, unrelated database sitting at THAT path is read
          # instead, silently, with no exception at all. One pass, not two
          # sequential gsubs: escaping # to %23 and THEN escaping the % that
          # produced would double-encode it to %2523.
          def escape_uri_path(path)
            path.gsub(/[%#?]/) { format("%%%02X", _1.ord) }
          end
        end
  end
end
