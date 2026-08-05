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

      class << self
        attr_reader :agent_name, :label_text, :documented_value, :verified_on_date, :declared_warnings

        FIDELITIES = %i[full messages metadata unsupported].freeze

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

      # Lazily enumerates the primary store (adapters declare it first). Each
      # consumed session costs one stat plus filename parsing — never a content
      # read. project_path is the exception and pays for itself on first access.
      def sessions
        layers.first.files.lazy.map { |path| build_session(path) }
      end

      # The cheap path matches the adapter's project encoding against the session
      # file's parent directory name — no reads (design doc section 7). The
      # encodings are lossy ("/a_b" and "/a/b" encode identically), which the
      # design accepts: forward-encoding is exact for real directories, and the
      # collision case requires two projects that differ only in separator.
      # Adapters without a rule compare recorded cwds, which reads each file once.
      def sessions_for_project(dir)
        dir = File.expand_path(dir)
        encoded = encode_project(dir)
        if encoded
          sessions.select { |session| File.basename(File.dirname(session.path)) == encoded }
        else
          sessions.select { |session| session.project_path == dir }
        end
      end

      # Distinct recorded project paths. This is the read-everything direction
      # (design doc section 7): the encodings cannot be reversed, so the recorded
      # cwd inside each file is the only reliable source. Sessions whose project
      # cannot be determined are excluded, not returned as nil.
      def project_paths
        sessions.map(&:project_path).force.compact.uniq
      end

      # --- Layer 2 hooks, overridable per adapter ---

      def session_id_from(path)
        File.basename(path, ".*")
      end

      # nil means this adapter has no cheap directory-name rule.
      def encode_project(_dir) = nil

      # nil means the project is unknown for this session. Adapters override
      # with a bounded read of their own metadata; Base cannot guess.
      def project_path_for(_path) = nil

      def started_at_for(path)
        File.birthtime(path)
      rescue NotImplementedError, Errno::ENOENT
        nil # some Linux filesystems cannot answer; nil beats a wrong guess
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

      def read_json(path)
        JSON.parse(File.read(path))
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, JSON::ParserError
        {}
      end

      def build_session(path)
        stat = File.stat(path)
        Session.new(
          agent: self.class.agent_name,
          id: session_id_from(path),
          path: path,
          started_at: started_at_for(path),
          updated_at: updated_at_for(path, stat),
          bytes: stat.size,
          format: layers.first.format,
          fidelity: self.class.fidelity_value
        ) { project_path_for(path) }
      end

      # Streams up to `limit` lines looking for a JSON record carrying `key`.
      # Bounded so a 2.6 GB session file costs a few KB, and tolerant of the
      # non-JSON or differently-shaped lines real logs contain.
      def scan_jsonl_for_key(path, key, limit: 25)
        File.foreach(path).with_index do |line, index|
          break if index >= limit

          begin
            record = JSON.parse(line)
          rescue JSON::ParserError, EncodingError
            next
          end
          return record if record.key?(key)
        end
        nil
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
        nil
      end
    end
  end
end
