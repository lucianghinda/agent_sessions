# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Opencode < Base
      agent :opencode
      label "opencode"
      documented :partly
      verified_on "2026-07-21"
      fidelity :full

      def self.reader_class = Readers::Opencode

      base_dir default: "~/.local/share/opencode", env: "XDG_DATA_HOME", env_join: "opencode"

      store :database, path: "opencode.db", format: :sqlite
      store :legacy, dir: "storage", format: :json, optional: true

      warning "pre-v1.2.0 storage/ tree may remain on disk after migration; " \
              "counting it alongside opencode.db double-counts sessions"

      # Where opencode keeps its data besides the declared default, in the
      # order they are tried. Taken from tokentelemetry's probe of the same
      # store (resources/tokentelemetry, _opencode_db_candidates) and NOT
      # verified here beyond the first: this machine has only
      # ~/.local/share/opencode. Before this list, a macOS user whose store
      # sits under Application Support got an empty result from an agent they
      # had used — the same class of bug the Cursor IDE adapter had.
      #
      # OPENCODE_DATA_DIR is the store's own variable and so outranks
      # XDG_DATA_HOME, which base_dir already honours; both are checked before
      # any hardcoded path, and a candidate only wins if it actually holds a
      # database, so an empty directory cannot shadow a real store.
      def self.data_dir_candidates(env, home)
        [
          env["OPENCODE_DATA_DIR"],
          (env["XDG_DATA_HOME"] && File.join(env["XDG_DATA_HOME"], "opencode")),
          File.join(home, ".local", "share", "opencode"),
          (File.join(home, "Library", "Application Support", "opencode") if platform_for == :macos),
          (env["APPDATA"] && File.join(env["APPDATA"], "opencode")),
          (env["LOCALAPPDATA"] && File.join(env["LOCALAPPDATA"], "opencode"))
        ].compact
      end

      # The declared default stands unless another candidate actually holds a
      # database. Falling back to it rather than to the first candidate that
      # merely exists keeps `where` printing a concrete, conventional path on
      # a machine with no opencode at all.
      def base_dir
        @base_dir ||= self.class.data_dir_candidates(@env, home)
                          .find { |dir| Dir.glob(File.join(escape_glob(dir), DATABASE_GLOB)).any? } || super
      end

      # opencode names its database per release channel — opencode.db,
      # opencode-stable.db — so the filename is a glob, not a constant
      # (tokentelemetry globs the same pattern). Unverified here: this machine
      # has only the plain name.
      DATABASE_GLOB = "opencode*.db"

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
        paths = database_paths
        return [].lazy if paths.empty?

        Enumerator.new do |yielder|
          seen = {}
          paths.each do |db_path|
            each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM session") do |row|
              # Channel databases can hold the same session — a store migrated
              # between channels keeps both files. Deduped by id, first
              # database wins, so one session is one row to a caller counting
              # them. tokentelemetry dedups the same way for the same reason.
              next if seen[row.first]

              seen[row.first] = true
              yielder << build_db_session(db_path, row)
            end
          end
        end.lazy
      end

      # The directory column holds the full recorded path, so filtering is a
      # WHERE clause instead of the Base read-and-compare loop.
      def sessions_for_project(dir)
        dir = File.expand_path(dir)
        paths = database_paths
        return [].lazy if paths.empty?

        Enumerator.new do |yielder|
          seen = {}
          paths.each do |db_path|
            each_session_row(db_path, "SELECT #{SESSION_COLUMNS} FROM session WHERE directory = ?", [dir]) do |row|
              next if seen[row.first]

              seen[row.first] = true
              yielder << build_db_session(db_path, row)
            end
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
        paths = []
        database_paths.each do |db_path|
          each_session_row(db_path, "SELECT DISTINCT directory FROM session ORDER BY directory") do |row|
            paths << row.first if row.first.is_a?(String)
          end
        end
        # Sorted after the union, not per database: SQL's ORDER BY only orders
        # within one file, and two channel databases concatenated would leave
        # `projects` unsorted — the one thing Base guarantees about it.
        paths.uniq.sort
      end

      # Base checks the declared path literally, which gets a machine holding
      # only a channel-named database wrong twice: its "is this agent
      # installed" gate sees no declared layer and skips the store checks
      # entirely, and the store check itself would report :fail on a real
      # store that is merely called something the declaration did not predict.
      #
      # Any file matching the glob satisfies the claim. The detail names what
      # was actually found, so a non-canonical filename is visible rather than
      # merely tolerated — the same reason detail_for prints a file count.
      def verify
        found = database_paths
        return super if found.empty?

        checks = super
        database = checks.find { |candidate| candidate.claim == "store database exists" }
        return checks.map { |c| c.claim == database&.claim && !c.pass? ? passing_database(found) : c } if database

        # The skip gate fired: Base returned one :skip and never looked at the
        # stores. Answer the store claim it never asked.
        [passing_database(found)] + checks.reject { |c| c.claim == "agent is installed" }
      end

      private

      def passing_database(found)
        check(:pass, "store database exists", found.join(", "))
      end

      # Every database in the resolved store directory, canonical name first
      # so its ids win the dedup above. Sorted for a stable order across runs;
      # Dir.glob's own order is filesystem-dependent.
      #
      # The existence check that used to live in each caller is this method
      # returning empty: a machine without opencode never opens anything, and
      # so never needs the sqlite3 gem (design doc section 9).
      def database_paths
        @database_paths ||= begin
          found = Dir.glob(File.join(escape_glob(base_dir), DATABASE_GLOB)).sort
          canonical = primary_layer.path
          found.include?(canonical) ? [canonical] + (found - [canonical]) : found
        end
      end

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
      # The open itself (read-only URI with escaped path, no immutable=1,
      # 5s busy_timeout) lives in AgentSessions::Sqlite with the evidence for
      # each choice — extracted when the opencode READER became its second
      # caller. What stays here is this adapter's answer to failure: a query
      # error becomes UnreadableStore, because a vanished or corrupt DATABASE
      # is the store's only source for every session — there is nothing
      # partial to return. Design doc section 10's "never write" caveat also
      # still belongs to this store: opening a WAL db even read-only touches
      # its -shm/-wal sidecars (SQLite's reader bookkeeping, confirmed
      # directly); a directory with no write permission surfaces as
      # SQLite3::ReadOnlyException → UnreadableStore, confirmed against a
      # chmod 0555 directory.
      #
      # Lock contention is NOT covered by a test: reliably reproducing it
      # needs a second process holding a write transaction for the exact
      # duration of the read — noted rather than left looking covered.
      def each_session_row(db_path, sql, params = [], &block)
        require_sqlite!
        db = nil
        begin
          db = Sqlite.open_readonly(db_path)
          db.execute(sql, params, &block)
        rescue SQLite3::Exception => e
          raise UnreadableStore, "#{db_path}: #{e.message}"
        ensure
          db&.close
        end
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
