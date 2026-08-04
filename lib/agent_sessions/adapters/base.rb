# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Base
      class << self
        attr_reader :agent_name, :label_text, :documented_value, :verified_on_date,
                    :base_dir_config, :store_configs, :declared_warnings

        private

        def agent(name) = @agent_name = name
        def label(text) = @label_text = text
        def documented(value) = @documented_value = value
        def verified_on(date) = @verified_on_date = Date.parse(date)

        def base_dir(default:, env: nil, env_join: nil)
          @base_dir_config = { default: default, env: env, env_join: env_join }
        end

        def store(kind, format:, dir: nil, path: nil, glob: nil, env: nil, optional: false)
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

      # ~ expands against the injected env, never the process environment,
      # so callers can resolve paths for a machine that is not their own.
      def expand(path)
        File.expand_path(path.sub(/\A~(?=\/|\z)/) { @env["HOME"] || Dir.home })
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

      def read_json(path)
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
