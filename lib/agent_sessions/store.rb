# frozen_string_literal: true

module AgentSessions
  Store = Data.define(
    :agent, :label, :documented, :verified_on,
    :effective, :layers, :env_overrides,
    :retention, :retention_source, :warnings
  ) do
    def documented? = documented == true
    def installed? = layers.any?(&:exists?)
    def format = effective.format
  end
end
