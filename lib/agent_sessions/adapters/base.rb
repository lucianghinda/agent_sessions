# frozen_string_literal: true

module AgentSessions
  module Adapters
    # Base class for every agent adapter. Subclass this directly, never another
    # adapter: the DSL keeps its configuration in singleton instance variables,
    # which Ruby does not carry down a second level of inheritance, so a subclass
    # of a subclass would silently declare nothing.
    #
    # An instance memoizes what it resolves. Build a new instance per resolution
    # rather than reusing one across changes to the env hash.
    class Base
      include HomeExpansion

      FIDELITIES = %i[full messages metadata unsupported].freeze

      # Caps how many bytes one iteration of a JSONL scan may pull into memory.
      # "One line" is not a bounded quantity on disk: a record carrying a pasted
      # file or a base64 image is routinely tens of MB, and a truncated file may
      # hold no newline at all. An over-long line arrives as chunks of this size,
      # which fail to parse and are skipped, so the scan gives up rather than
      # reading a 2.6 GB file into a single String.
      MAX_LINE_BYTES = 1_000_000

      class << self
        attr_reader :agent_name, :label_text, :documented_value, :verified_on_date, :declared_warnings

        # :unsupported is the honest default for an adapter that has not declared
        # what a reader could reconstruct from its format.
        def fidelity_value = @fidelity_value || :unsupported

        def base_dir_config
          @base_dir_config || raise(Error, "#{inspect} declares no base_dir")
        end

        def store_configs
          @store_configs || raise(Error, "#{inspect} declares no store")
        end

        private

        def agent(name) = @agent_name = name
        def label(text) = @label_text = text
        def documented(value) = @documented_value = value
        def verified_on(date) = @verified_on_date = Date.parse(date)

        def fidelity(value)
          unless FIDELITIES.include?(value)
            raise ArgumentError, "fidelity #{value.inspect} must be one of #{FIDELITIES.join(", ")}"
          end

          @fidelity_value = value
        end

        def base_dir(default:, env: nil, env_join: nil)
          @base_dir_config = { default: default, env: env, env_join: env_join }
        end

        def store(kind, format:, dir: nil, path: nil, glob: nil, env: nil, optional: false)
          raise ArgumentError, "store #{kind.inspect} needs exactly one of dir: or path:" if [dir, path].compact.size != 1

          @store_configs ||= []
          @store_configs << {
            kind: kind, format: format, dir: dir, path: path,
            glob: glob, env: env, optional: optional
          }
        end

        def warning(message)
          @declared_warnings ||= []
          @declared_warnings << message
        end
      end

      def initialize(env: ENV)
        @env = env
      end

      def locate
        Store.new(
          agent: self.class.agent_name,
          label: self.class.label_text,
          documented: self.class.documented_value,
          verified_on: self.class.verified_on_date,
          effective: layers.first,
          layers: layers,
          env_overrides: env_overrides,
          retention: retention,
          retention_source: retention_source,
          warnings: warnings
        )
      end

      # Checks every declared store against disk. The design doc says each adapter
      # declares its own checks, and each one does: its store_configs decide what is
      # looked for and whether an absence is a failure or drift. Content-level checks
      # (first record type, encoding round-trip) need file reads and wait for Layer 3.
      # An adapter that needs its own can override this and call super.
      #
      # The skip gate is the same signal Store#installed? uses: any declared store
      # exists. It is deliberately NOT base-dir existence — ~/.cursor is created by
      # the Cursor editor with no agent store in it (observed 2026-08-05), and the
      # old gate made doctor report FAIL while `where` said "(not installed)".
      # A missing store proves nothing on its own (never used? layout moved? the
      # gem cannot tell), so :fail is reserved for the one case with evidence:
      # some store exists, proving the agent records data here, while a required
      # one is absent — the layout-moved signature.
      def verify
        unless layers.any?(&:exists?)
          detail = if Dir.exist?(base_dir)
                     "#{base_dir} exists but holds none of the declared stores"
                   else
                     "#{base_dir} does not exist"
                   end
          return [check(:skip, "agent is installed", detail)]
        end

        self.class.store_configs.map do |config|
          location = resolve(config)
          claim = "store #{config[:kind]} exists"
          if location.exists?
            check(:pass, claim, detail_for(location))
          elsif config[:optional]
            check(:drift, claim, "#{location.path} not found (optional; undocumented layouts drift)")
          else
            check(:fail, claim, "#{location.path} not found")
          end
        end
      end

      # Lazily enumerates the primary store. Each consumed session costs one stat
      # plus filename parsing — never a content read. project_path is the exception
      # and pays for itself on first access.
      #
      # A store the gem has no layout for is refused rather than reported empty:
      # Location#enumerable? exists precisely so "nothing here to enumerate" and
      # "enumerated, found none" stay distinguishable, and silently returning no
      # sessions is this gem's worst failure mode.
      def sessions
        unless primary_layer.enumerable?
          raise Error, "#{self.class.agent_name} store #{primary_layer.kind} at " \
                       "#{primary_layer.path} has no known layout to enumerate"
        end

        primary_layer.files.lazy.filter_map { |path| build_session(path) }
      end

      # Match by RECORDED cwd, exact, per session (design doc section 7,
      # revised 2026-08-05 — the third design for this method, kept honest
      # here because the next reader deserves to know why it is not "cheap").
      # The first two designs were built and disproved against a real store,
      # not in theory:
      #
      #   1. Directory-name matching (the original design) assumed a
      #      session's parent directory equals encode(its own recorded cwd).
      #      A project rename breaks that: the agent keeps writing under the
      #      OLD encoded directory, so two directories can hold live sessions
      #      for the SAME current cwd, and name-only matching silently
      #      dropped the stale one — false negatives, the failure mode this
      #      gem treats as worst (decision 11).
      #
      #   2. One-read-per-directory sampling (the first fix for #1) assumed
      #      sessions within a directory share a cwd, to keep the match
      #      sublinear. Reading a real renamed project's stale directory
      #      disproved that: two of its three sessions had been resumed after
      #      the rename and recorded the NEW cwd; the third was never resumed
      #      and still recorded the OLD one. Sampling one session and
      #      applying its verdict to the whole directory is wrong in BOTH
      #      directions on the same store — it invented a false positive
      #      here, and a different glob order would just as easily have
      #      reproduced #1's false negative for that same directory.
      #      Approximate cwd resolution doesn't make the error smaller; it
      #      just moves where it lands.
      #
      # Measured cost of reading every session instead of sampling: 0.17 ms
      # per session (68 real Claude sessions, full sweep, 0.012s total) — 0.7s
      # extrapolated to a 4,000-session store. That is what the sampling
      # complexity was buying, and it is not a trade worth making: the
      # enumerator is already lazy, so a caller taking first(n) never pays
      # for sessions it never asked about, and even the worst case (every
      # session checked, no match) stays under a second on a store two
      # orders of magnitude larger than anything observed.
      #
      # A session whose own cwd cannot be read (the scan gave up, the file is
      # unreadable, the adapter declares no reader) falls back to comparing
      # ITS OWN directory's name against the encoding, when the adapter
      # declares one — this is the only thing encode_project still buys: it
      # keeps a session with an unreadable header from becoming invisible,
      # without resolving an unknown project for every other session that
      # happens to share its directory.
      def sessions_for_project(dir)
        dir = File.expand_path(dir)
        encoded = encode_project(dir)
        sessions.select do |session|
          # expand_path does not resolve symlinks, so a cwd recorded as
          # /private/tmp/x will not match a caller's /tmp/x on macOS.
          # Deliberate: realpath would cost a stat per comparison to fix a
          # rare mismatch.
          cwd = session.project_path
          next cwd == dir unless cwd.nil?

          encoded && project_dir_name(session.path) == encoded
        end
      end

      # Distinct recorded project paths, sorted. This is the read-everything
      # direction (design doc section 7): the encodings cannot be reversed, so the
      # recorded cwd inside each file is the only reliable source. Sessions whose
      # project cannot be determined are excluded, not returned as nil.
      #
      # Sorted rather than left in glob order because a stable order is what makes
      # `projects` output diffable and `du --by project` deterministic — and
      # adapters answering from a database would otherwise impose their own.
      def project_paths
        sessions.filter_map(&:project_path).uniq.force.sort
      end

      # --- Layer 2 hooks, overridable per adapter ---

      def session_id_from(path)
        File.basename(path, ".*")
      end

      # nil means this adapter has no directory-name fallback rule. Used only
      # by sessions_for_project, and only for a session whose own recorded
      # cwd could not be read. When overridden: dir arrives pre-expanded here
      # from sessions_for_project (File.expand_path), which is the
      # precondition an override may rely on — a direct caller must pass an
      # absolute, expanded path itself, or the encoding is nonsense ("app",
      # "~/app", and a trailing slash all encode differently from the
      # canonical form real project directories were named from).
      def encode_project(_dir) = nil

      # The directory whose name the encoding must match, when
      # sessions_for_project falls back to it. Overridable: not every store
      # puts the encoded project directly above the session file — cursor_ide
      # nests projects/<name>/agent-transcripts/*, where the immediate parent
      # is agent-transcripts and matching it would find nothing, silently.
      def project_dir_name(path) = File.basename(File.dirname(path))

      # nil means the project is unknown for this session. Adapters override
      # with a bounded read of their own metadata; Base cannot guess.
      def project_path_for(_path) = nil

      # Both time hooks take the stat the enumerator already holds, so a session
      # still costs one syscall. path is passed for adapters that answer from a
      # sibling metadata file instead.
      #
      # nil beats a wrong guess when the filesystem cannot answer at all — and it
      # says so through ENOSYS/EPERM from statx as often as NotImplementedError.
      def started_at_for(_path, stat)
        stat.birthtime
      rescue NotImplementedError, SystemCallError
        nil
      end

      def updated_at_for(_path, stat) = stat.mtime

      def base_dir
        config = self.class.base_dir_config
        override = presence(config[:env] && @env[config[:env]])
        if override
          expand(config[:env_join] ? File.join(override, config[:env_join]) : override)
        else
          expand(config[:default])
        end
      end

      def retention = nil
      def retention_source = :none

      def warnings
        (self.class.declared_warnings || []).dup
      end

      private

      def layers
        @layers ||= self.class.store_configs.map { |config| resolve(config) }
      end

      # The store sessions live in. Adapters declare it first, by convention.
      def primary_layer = layers.first

      # single_file is a property of the declaration, not of the resolved path: a
      # store-level env override replaces where the layer lives without changing
      # whether it is one file or a directory.
      def resolve(config)
        override = presence(config[:env] && @env[config[:env]])
        root = override ? expand(override) : File.join(base_dir, config[:dir] || config[:path])
        Location.new(
          kind: config[:kind], path: root, format: config[:format],
          glob: config[:glob], single_file: !config[:path].nil?
        )
      end

      def env_overrides
        names = [self.class.base_dir_config[:env], *self.class.store_configs.map { |c| c[:env] }]
        names.compact.uniq.map { |name| EnvOverride.new(name: name, value: presence(@env[name])) }
      end

      def presence(value)
        value && !value.empty? ? value : nil
      end

      def env_active?(name)
        !presence(@env[name]).nil?
      end

      def check(status, claim, detail)
        Check.new(agent: self.class.agent_name, status: status, claim: claim, detail: detail)
      end

      # A single file's own path is the whole detail; counting it "(1 file)" adds noise.
      def detail_for(location)
        return location.path unless location.glob

        count = location.files.size
        "#{location.path} (#{count} file#{"s" unless count == 1})"
      end

      # SystemCallError, not the four Errno constants this used to list: those
      # four were the failures observed, not the exhaustive set that can
      # happen. Task 7 (Cursor) made this reachable from a hook that runs
      # EAGERLY for every session (started_at_for/updated_at_for read a
      # sibling meta.json to answer, not lazily like project_path), so a
      # single unreadable sibling file now has the blast radius of an
      # unrescued raise: it takes the WHOLE listing down, not just its own
      # session — Enumerator::Lazy#filter_map does not isolate one failing
      # iteration. Two errnos found this way, both real, neither in the old
      # list: ELOOP (a symlink loop — Location#files already rescues this on
      # the glob side, so the codebase had already judged it reachable, and
      # this method's own test reproduces it directly against a real
      # symlink-loop meta.json) and EPERM (macOS TCC denies a protected path
      # with EPERM, not EACCES — reported and reproduced during code review
      # by reading a TCC-protected path directly; not independently
      # re-verified here, but Base#started_at_for already rescues
      # SystemCallError and its own comment names EPERM, so this method was
      # simply behind its sibling, not making a different judgment call).
      # This gets more likely, not less, once cursor_ide is repointed at
      # ~/Library/Application Support/… in a future release — that path is
      # TCC territory on macOS.
      #
      # What this still does NOT catch: a FIFO (named pipe) named meta.json
      # blocks File.read forever rather than raising anything — same class of
      # problem (a store directory containing something other than a plain
      # file), no cheap fix, and out of scope here.
      def read_json(path)
        JSON.parse(File.read(path))
      rescue SystemCallError, JSON::ParserError
        {}
      end

      # nil drops the session from the enumeration. A file that vanished between
      # the glob and its stat is one fewer session, not an error: enumeration is
      # lazy, so that window spans the whole listing, and agents rotate and
      # compact these logs while a caller is still reading them.
      #
      # The rescue covers the stat and nothing else. Wrapping the hooks too would
      # mean an adapter whose started_at_for raised EACCES silently returned zero
      # sessions — a misdeclared adapter erasing a listing rather than failing.
      # A hook that raises is a programming error and surfaces, matching `all`.
      #
      # SystemCallError, not just ENOENT/EACCES, for the same reason
      # started_at_for's own rescue already widened past those two (see its
      # comment) and read_json's just did above: the FILE this stats can
      # itself be a symlink loop (ELOOP) or TCC-denied (EPERM on macOS), not
      # only vanished or permission-denied in the two ways originally listed.
      def build_session(path)
        stat = File.stat(path)
      rescue SystemCallError
        nil
      else
        Session.new(
          agent: self.class.agent_name,
          id: session_id_from(path),
          path: path,
          started_at: started_at_for(path, stat),
          updated_at: updated_at_for(path, stat),
          bytes: stat.size,
          format: primary_layer.format,
          fidelity: self.class.fidelity_value
        ) { project_path_for(path) }
      end

      # Streams a JSONL file looking for a record carrying `key`. Bounded twice
      # over — `limit` caps the iterations, MAX_LINE_BYTES caps each read — so the
      # worst case is a few tens of MB even for a file with no newlines in it.
      # Tolerant of the non-JSON lines and non-object records real logs contain:
      # a scan that gives up is worth more here than one that raises.
      #
      # Presence of `key` alone is not "found": a record can carry it with a
      # null or wrong-typed value, which would otherwise stop the scan and
      # permanently shadow a later, usable record — or hand a caller a Hash
      # where it expected a String, which is exactly what turns project_paths'
      # .uniq.sort into an ArgumentError from one malformed record. An optional
      # block is the value check, evaluated only once presence already holds;
      # it defaults to accepting whatever presence accepted, so a caller with
      # no block sees no behavior change.
      def scan_jsonl_for_key(path, key, limit: 25)
        File.foreach(path, "\n", MAX_LINE_BYTES).with_index do |line, index|
          break if index >= limit

          begin
            record = JSON.parse(line)
          rescue JSON::ParserError, EncodingError
            next
          end
          next unless record.is_a?(Hash) && record.key?(key)
          next if block_given? && !yield(record)

          return record
        end
        nil
      # SystemCallError, matching read_json and build_session. The enumerated
      # Errno list this replaced missed EPERM, which is what macOS returns for a
      # TCC-protected path rather than EACCES, and ELOOP. The exposure here is
      # narrower than read_json's — build_session stats the session file first and
      # drops it on any SystemCallError, so a file that fails outright never
      # reaches this — but a file that stats cleanly and then fails on read does,
      # and the three rescues disagreeing on which errnos count is the kind of
      # inconsistency that becomes a bug the moment one of them moves.
      rescue SystemCallError
        nil
      end
    end
  end
end
