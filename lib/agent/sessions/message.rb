# frozen_string_literal: true

module Agent
  module Sessions
          # One turn. `role` is normalized to :user, :assistant, :system or :tool, with
          # :unknown for a role the adapter did not recognize — the four the spec names
          # were written before any real corpus was read, and Codex promptly said
          # "developer".
          #
          # raw is never dropped (Layer 3 rule 1): when this normalization is wrong or
          # incomplete, a caller escapes the abstraction instead of forking the gem.
          #
          # usage and model are nil wherever the format does not put them on the
          # message itself — Codex records tokens in separate event records and the
          # model in its session header, so its messages carry neither; the reader's
          # session-level `usage` is where those formats answer. A nil here means
          # "not recorded on this message", never "zero tokens".
          Message = Data.define(:role, :at, :parts, :raw, :usage, :model) do
            self::ROLES = %i[user assistant system tool unknown].freeze

            def initialize(role:, at:, parts:, raw:, usage: nil, model: nil)
              roles = self.class::ROLES
              raise ArgumentError, "role #{role.inspect} must be one of #{roles.join(", ")}" unless roles.include?(role)

              super
            end

            # Concatenated :text parts, as the design doc specifies — no separator
            # inserted, because a separator is a formatting decision this layer has no
            # business making. A caller that needs the boundaries has `parts`.
            def text
              parts.select { |part| part.type == :text }.map(&:text).join
            end
          end
  end
end
