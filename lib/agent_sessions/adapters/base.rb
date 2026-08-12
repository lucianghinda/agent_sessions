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
    #
    # What lives here is Layer 1: where a store is, what it declares, and whether
    # disk agrees. Turning that store into sessions is Layer 2 and lives in
    # Enumeration, included below — the two halves met at 460 lines in one class
    # and were split before Layer 3 readers could make it three.
    class Base
      include HomeExpansion
      include Enumeration

      FIDELITIES = %i[full messages metadata unsupported].freeze

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

        # The Layer 3 reader for this agent, or nil while it has none. nil is
        # what makes AgentSessions.read raise UnsupportedFormat instead of
        # handing back a reader that quietly yields nothing.
        def reader_class = nil

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

      def layer(kind)
        layers.find { |candidate| candidate.kind == kind }
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

      # Location#files escapes its own path for the reason its comment gives —
      # a resolved path may legitimately contain glob metacharacters, and
      # unescaped they are read as syntax and silently match nothing. An
      # adapter globbing a path it was handed needs the same protection.
      def escape_glob(path)
        path.gsub(/[\\{}\[\]*?]/) { |char| "\\#{char}" }
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

    end
  end
end
