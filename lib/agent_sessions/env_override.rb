# frozen_string_literal: true

module AgentSessions
  EnvOverride = Data.define(:name, :value) do
    def active? = !value.to_s.empty?
  end
end
