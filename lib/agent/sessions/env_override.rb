# frozen_string_literal: true

module Agent
  module Sessions
        EnvOverride = Data.define(:name, :value) do
          def active? = !value.to_s.empty?
        end
  end
end
