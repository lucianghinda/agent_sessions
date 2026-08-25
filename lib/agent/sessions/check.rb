# frozen_string_literal: true

module Agent
  module Sessions
        Check = Data.define(:agent, :status, :claim, :detail) do
          def pass? = status == :pass
        end
  end
end
