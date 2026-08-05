# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Opencode < Base
      agent :opencode
      label "opencode"
      documented :partly
      verified_on "2026-07-21"
      fidelity :full

      base_dir default: "~/.local/share/opencode", env: "XDG_DATA_HOME", env_join: "opencode"

      store :database, path: "opencode.db", format: :sqlite
      store :legacy, dir: "storage", format: :json, optional: true

      warning "pre-v1.2.0 storage/ tree may remain on disk after migration; " \
              "counting it alongside opencode.db double-counts sessions"

      SESSION_COLUMNS = "id, directory, time_created, time_updated"

      # Sessions are rows, not files, so the Base glob enumeration is replaced by
      # a deferred query: it runs at first consumption, and only if the database
      # exists. The existence check comes FIRST so machines without opencode
      # never need sqlite3 at all (design doc section 9).
      #
      # Row order is deliberately unspecified: no ORDER BY, so rows arrive in
      # whatever order SQLite's own scan produces (rowid order, absent an
      # index that would change it) — unlike the other six adapters, which are
      # path-sorted for free by Dir.glob. Invisible today because nothing here
      # sorts before Task 10 does its own sort_by(&:updated_at); stated so a
      # future caller of THIS method directly does not come to depend on
      # insertion order looking stable.
      #
      # The gap between this check and the open below is a real TOCTOU window —
      # opencode could delete or migrate the file in between — but the open
      # that follows a vanished file raises SQLite3::CantOpenException (verified
      # directly), which each_session_row already turns into UnreadableStore.
      # That is judged the right answer, not a bug to special-case: unlike
      # Base's own glob-then-stat race (one file silently missing from a
      # multi-file listing, so build_session's rescue drops it and moves on),
      # a vanished DATABASE is the store's only source for every session, so
      # there is nothing partial to return — "the store I just confirmed
      # exists is now unreadable" is what happened, and UnreadableStore says
      # exactly that.
      #
      # Opens once per consumption, not once per instance: `sessions`,
      # `sessions_for_project` and `project_paths` each open, query and close
      # their own connection through each_session_row. That costs an extra
      # open when a caller uses more than one of the three, but keeps every
      # method independently correct rather than threading a shared handle
      # through them — and Enumerator.new's block does not even run until the
      # RETURNED lazy enumerator is consumed, so a caller that builds `sessions`
      # and never touches it opens nothing at all. Confirmed empirically (not
      # just assumed from Enumerator's docs) that the `ensure db&.close` inside
      # each_session_row fires promptly either way a caller can stop early —
      # `.lazy.first(n)` and an external `each { break }` both unwind the
      # generator fiber immediately, before the outer call returns — so a
      # caller taking `sessions.first` never leaves a connection open waiting
      # for GC to reclaim the fiber.
      def sessions
        db_path = primary_layer.path
        return [].lazy unless File.exist?(db_path)

        Enumerator.new do |yielder|
          each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM session") do |row|
            yielder << build_db_session(db_path, row)
          end
        end.lazy
      end

      # The directory column holds the full recorded path, so filtering is a
      # WHERE clause instead of the Base read-and-compare loop.
      def sessions_for_project(dir)
        dir = File.expand_path(dir)
        db_path = primary_layer.path
        return [].lazy unless File.exist?(db_path)

        Enumerator.new do |yielder|
          each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM session WHERE directory = ?", [dir]) do |row|
            yielder << build_db_session(db_path, row)
          end
        end.lazy
      end

      # ORDER BY matches the sorted order Base guarantees, so `projects` output is
      # stable and diffable whichever adapter answers it. is_a?(String) excludes
      # a row whose directory is NULL (build_db_session's guard, same rule 2
      # container check) rather than letting a literal nil sort in among real
      # paths — "excluded, not nil", matching Base's project_paths docstring.
      # .uniq is needed on top of SQL's own DISTINCT: SQLite's DISTINCT treats a
      # BLOB and a byte-identical TEXT value as different rows (confirmed
      # directly — typeof reports "text" vs "blob" for the same bytes even
      # though the sqlite3 gem returns both to Ruby as String, see
      # build_db_session's comment), so without this a blob/text pair with
      # identical bytes would surface as two entries where Base's own
      # `.uniq.sort` would collapse them to one.
      def project_paths
        db_path = primary_layer.path
        return [] unless File.exist?(db_path)

        paths = []
        each_session_row(db_path, "SELECT DISTINCT directory FROM session ORDER BY directory") do |row|
          paths << row.first if row.first.is_a?(String)
        end
        paths.uniq
      end

      private

      # `directory` carries TEXT affinity, so any numeric literal written to it
      # is converted to text at INSERT time (SQLite's own rule, the mirror image
      # of the INTEGER-affinity coercion `session_time` guards below) — but a
      # NULL that reached this NOT-NULL column the way a NOT-NULL column added
      # via a defaultless ALTER TABLE can hold NULL for pre-existing rows
      # survives affinity untouched, and so does an Integer that landed in a
      # column SQLite gave BLOB (no-conversion) affinity rather than TEXT (the
      # test fixture for this reproduces it — a bare, undeclared column type).
      # is_a?(String) catches both. It does NOT, however, catch an actual BLOB
      # storage class value the way an earlier version of this comment claimed:
      # confirmed directly that the sqlite3 gem returns a BLOB to Ruby as a
      # plain String (ASCII-8BIT-encoded, but still is_a?(String)) — the guard
      # is correct and load-bearing for what it DOES catch (rule 2's container
      # check, the same one Cursor's `cwd.is_a?(String)` applies to the
      # equivalent field, and the "excluded, not nil" project_paths needs per
      # Base's own docstring), just not a universal type filter. project_paths
      # separately guards the BLOB/TEXT duplicate this leaves open.
      def build_db_session(db_path, row)
        id, directory, created_ms, updated_ms = row
        project_path = directory.is_a?(String) ? directory : nil
        Session.new(
          agent: self.class.agent_name, id: id, path: db_path, project_path: project_path,
          started_at: session_time(created_ms),
          updated_at: session_time(updated_ms) || session_time(created_ms) || db_mtime(db_path),
          bytes: nil, # rows in a shared database; a file size would be a lie
          format: primary_layer.format, fidelity: self.class.fidelity_value
        )
      end

      # Mirrors Cursor's meta_time guard against the identical failure, reached
      # by a different route: time_created/time_updated carry INTEGER affinity,
      # which converts a numeric-LOOKING text value to a number at INSERT time
      # but leaves non-numeric text (or a hand-edited NULL, despite NOT NULL —
      # see build_db_session's comment on the same quirk for `directory`)
      # stored as-is. is_a?(Numeric) rejects that. A value that passes but is
      # merely huge (an absurd but real millisecond count) still overflows to
      # Infinity once forced through Float by `/ 1000.0`, and Time.at(Infinity)
      # raises FloatDomainError uncaught — rule 3's failure mode, one row
      # taking the whole enumeration down. seconds.finite? is checked AFTER the
      # division for the same reason Cursor's is: a finite Integer literal
      # hundreds of digits long still overflows only once divided, so checking
      # millis' own finiteness first would miss it.
      #
      # nil beats a wrong guess here for the same reason Base's started_at_for
      # prefers nil to guessing: the only fallback available for a shared-db
      # row is the database FILE's own stat, which would print the identical
      # timestamp for every session in the store regardless of when each one
      # actually happened — a plausible-looking wrong value is worse than an
      # honest unknown one.
      def session_time(millis)
        return nil unless millis.is_a?(Numeric)

        seconds = millis / 1000.0
        Time.at(seconds) if seconds.finite?
      end

      # CRITICAL, caught in review: plan decision 5 makes updated_at a
      # cross-adapter invariant — "never nil; started_at may be" — because
      # every file-based adapter gets it for free from Base#updated_at_for =
      # stat.mtime, which cannot be nil. opencode is the first adapter that
      # CAN return nil here (session_time can fail on both created_ms and
      # updated_ms independently), and a nil is not a value this reader gets
      # to invent locally: Task 9's `since` filter and Task 10's
      # sort_by(&:updated_at) both assume the invariant holds, and one
      # malformed row in a 359-row shared database reaching either would take
      # the WHOLE cross-agent listing down with an ArgumentError or
      # NoMethodError — rule 3's failure mode, relocated one layer up and past
      # every rescue, not removed. build_db_session's fallback chain
      # (updated_ms -> created_ms -> db_mtime) keeps the invariant instead:
      # time_created is a real per-session timestamp, not a guess, so it is
      # tried before falling back to the database FILE's own mtime, which is
      # reached only when a row's own pair of timestamps are BOTH malformed —
      # it is not this session's timestamp, but it is a true upper bound on
      # when anything in the store last changed, and unlike stat.birthtime
      # it is never allowed to be nil either: File.mtime can still raise
      # SystemCallError in the narrow window between a successful query and
      # this call (the same class of race Base's own started_at_for guards
      # its stat against), and letting THAT reach the caller unrescued would
      # reintroduce the exact bug this method exists to close. Time.now is
      # the true last resort — an honest "unknown, treat as just now" — so
      # this method, unlike every other timestamp helper in this file, is
      # never allowed to return nil.
      def db_mtime(db_path)
        @db_mtime ||= begin
          File.mtime(db_path)
        rescue SystemCallError
          Time.now
        end
      end

      # require_sqlite! must stay OUTSIDE the begin/rescue: if it raised inside,
      # Ruby would evaluate the SQLite3::Exception rescue clause while matching
      # and hit NameError, because the constant was never loaded.
      #
      # No immutable=1: it tells SQLite to trust that the file will never
      # change and skip locking AND the WAL entirely, reading only the base
      # table file — against a live, WAL-mode opencode.db that means silently
      # missing every committed-but-not-yet-checkpointed session, which is
      # worse than the alternative this method accepts instead: opening a
      # WAL-mode db even read-only makes SQLite create or touch the -shm
      # sidecar (and an empty -wal, if neither exists yet) as part of its own
      # reader-bookkeeping — confirmed directly (write a WAL db, close it so
      # both sidecars are gone, then reopen mode=ro and query: both files
      # reappear). That is SQLite's own concurrency machinery recording that a
      # reader is active, not this gem writing session data anywhere, and the
      # actual opencode.db table content is never touched by it — but it does
      # mean design doc section 10 promise 1 ("never write") holds only at the
      # level of "never touches the recorded sessions," not "zero bytes change
      # under the store directory," for this one adapter. A directory with no
      # write permission at all (as opposed to the file itself) surfaces that
      # limit directly: SQLite cannot create/open the -shm file and raises
      # SQLite3::ReadOnlyException, which each_session_row's rescue below
      # turns into UnreadableStore like any other query failure — confirmed
      # directly against a chmod 0555 directory, not assumed.
      #
      # busy_timeout gives SQLite up to 5s to retry internally against a lock
      # held by opencode's own live writer before giving up — opencode may be
      # running while this reads (design doc section 9), and a WAL writer's
      # lock is normally held only for the instant of a commit, not the whole
      # session, so a lock that has not cleared within 5s is a stuck process,
      # not ordinary contention. Without this, SQLite3::BusyException fires on
      # the first attempt with no retry at all, turning routine contention on
      # a live store into the same UnreadableStore raised for a genuinely
      # corrupt file — a real distinction (design doc section 9 draws it
      # explicitly) that this timeout narrows without pretending to close:
      # a writer that is ITSELF stuck for 5+ seconds still surfaces as
      # UnreadableStore, same as before, just no longer on ordinary contention.
      # NOT covered by a test: reliably reproducing lock contention needs a
      # second process or thread holding a write transaction for the exact
      # duration of the read, which nothing here attempts — noted rather than
      # left looking covered.
      def each_session_row(db_path, sql, params = [], &block)
        require_sqlite!
        db = nil
        begin
          db = SQLite3::Database.new(
            "file:#{escape_uri_path(db_path)}?mode=ro",
            flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI
          )
          db.busy_timeout = 5_000
          db.execute(sql, params, &block)
        rescue SQLite3::Exception => e
          raise UnreadableStore, "#{db_path}: #{e.message}"
        ensure
          db&.close
        end
      end

      # IMPORTANT, caught in review: SQLite's URI parser gives `%`, `#` and
      # `?` syntactic meaning, and db_path was being interpolated raw. `#`
      # starts a fragment (silently truncating the path there); `?` starts
      # the query string, colliding with the `?mode=ro` this method appends.
      # The worst case, confirmed directly: a path segment that merely
      # CONTAINS a valid-looking percent-escape — a directory literally named
      # "a%23b" — gets that escape DECODED by the URI parser into a different
      # path ("a#b"), so a second, unrelated database sitting at THAT path is
      # read instead, silently, with no exception at all. Escaping all three
      # in one pass over the ORIGINAL string is what keeps db_path a literal
      # string rather than partial URI grammar — Location#files draws the
      # same line for glob metacharacters, on the same reasoning: a resolved
      # path may legitimately contain them. One pass, not two sequential
      # gsubs (escape # and ? first, then % after): escaping # to %23 and
      # THEN escaping the % that produced would double-encode it to %2523,
      # corrupting the very escape this method exists to produce correctly.
      def escape_uri_path(path)
        path.gsub(/[%#?]/) { format("%%%02X", _1.ord) }
      end

      def require_sqlite!
        require "sqlite3"
      rescue LoadError
        raise MissingDependency,
              "opencode sessions live in opencode.db (SQLite); add the sqlite3 gem to enumerate them"
      end
    end
  end
end
