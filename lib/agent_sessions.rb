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
require_relative "agent_sessions/adapters/claude"
require_relative "agent_sessions/adapters/codex"
require_relative "agent_sessions/adapters/pi"
require_relative "agent_sessions/adapters/amp"
require_relative "agent_sessions/adapters/opencode"
require_relative "agent_sessions/adapters/cursor"
require_relative "agent_sessions/adapters/cursor_ide"
require_relative "agent_sessions/audit"

module AgentSessions
  STALE_AFTER_DAYS = 90

  class << self
    # Re-registering a name deliberately replaces it, so a consumer can ship a
    # corrected adapter for an agent whose layout moved before the gem catches up.
    def register(adapter_class)
      name = adapter_class.agent_name
      raise Error, "#{adapter_class.inspect} declares no agent name" if name.nil?

      registry[name] = adapter_class
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

    def verify(agent = nil, env: ENV)
      targets = agent ? [adapter_for(agent)] : registry.values
      targets.flat_map { |klass| klass.new(env: env).verify }
    end

    def doctor(agent = nil, env: ENV, today: Date.today)
      targets = agent ? [adapter_for(agent)] : registry.values
      staleness = targets.map do |klass|
        age = (today - klass.verified_on_date).to_i
        if age > STALE_AFTER_DAYS
          Check.new(agent: klass.agent_name, status: :drift, claim: "verified within #{STALE_AFTER_DAYS} days",
                    detail: "last verified #{klass.verified_on_date} (#{age} days ago)")
        else
          Check.new(agent: klass.agent_name, status: :pass, claim: "verified within #{STALE_AFTER_DAYS} days",
                    detail: "last verified #{klass.verified_on_date}")
        end
      end
      verify(agent, env: env) + staleness
    end

    def audit(env: ENV)
      Audit.new(all(env: env), env: env).report
    end

    private

    def adapter_for(agent)
      registry.fetch(agent) do
        raise UnknownAgent, "unknown agent: #{agent.inspect} (known: #{registry.keys.join(", ")})"
      end
    end
  end
end

AgentSessions.register(AgentSessions::Adapters::Claude)
AgentSessions.register(AgentSessions::Adapters::Codex)
AgentSessions.register(AgentSessions::Adapters::Pi)
AgentSessions.register(AgentSessions::Adapters::Amp)
AgentSessions.register(AgentSessions::Adapters::Opencode)
AgentSessions.register(AgentSessions::Adapters::Cursor)
AgentSessions.register(AgentSessions::Adapters::CursorIde)
