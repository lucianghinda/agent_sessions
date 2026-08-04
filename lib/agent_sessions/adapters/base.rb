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
      def verify
        unless Dir.exist?(base_dir)
          return [check(:skip, "agent is installed", "#{base_dir} does not exist")]
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

      def resolve(config)
        override = presence(config[:env] && @env[config[:env]])
        root = override ? expand(override) : File.join(base_dir, config[:dir] || config[:path])
        Location.new(kind: config[:kind], path: root, format: config[:format], glob: config[:glob])
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

      def detail_for(location)
        return location.path unless location.glob

        count = location.matches.size
        "#{location.path} (#{count} file#{"s" unless count == 1})"
      end

      def read_json(path)
        JSON.parse(File.read(path))
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, JSON::ParserError
        {}
      end
    end
  end
end
