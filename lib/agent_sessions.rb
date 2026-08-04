# frozen_string_literal: true

require "json"
require "date"

require_relative "agent_sessions/version"
require_relative "agent_sessions/errors"
require_relative "agent_sessions/env_override"
require_relative "agent_sessions/location"
require_relative "agent_sessions/store"
require_relative "agent_sessions/check"
require_relative "agent_sessions/adapters/base"

module AgentSessions
  class << self
    def register(adapter_class)
      registry[adapter_class.agent_name] = adapter_class
    end

    def registry
      @registry ||= {}
    end

    def agents = registry.keys

    def locate(agent, env: ENV)
      adapter_for(agent).new(env: env).locate
    end

    def all(env: ENV)
      registry.keys.map { |agent| locate(agent, env: env) }
    end

    def installed(env: ENV)
      all(env: env).select(&:installed?)
    end

    private

    def adapter_for(agent)
      registry.fetch(agent) do
        raise UnknownAgent, "unknown agent: #{agent.inspect} (known: #{registry.keys.join(", ")})"
      end
    end
  end
end
