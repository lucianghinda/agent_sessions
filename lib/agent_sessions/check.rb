# frozen_string_literal: true

module AgentSessions
  Check = Data.define(:agent, :status, :claim, :detail) do
    def pass? = status == :pass
  end
end
