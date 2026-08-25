# frozen_string_literal: true

module Agent
  module Sessions
          # One piece of a message. `type` is the normalized vocabulary (design doc §5);
          # everything an agent said that this gem could not classify arrives as
          # :unknown rather than as an exception, and the message's `raw` still holds it.
          #
          # text carries the readable content for :text, :thinking and :tool_result.
          # name and call_id are tool plumbing, nil elsewhere. An :image part has
          # neither — its URL or payload stays in raw, because normalizing an image
          # would mean deciding whether to load it, and reading is stat-cheap by design.
          Part = Data.define(:type, :text, :name, :call_id) do
            self::TYPES = %i[text thinking tool_use tool_result image unknown].freeze

            def initialize(type:, text: nil, name: nil, call_id: nil)
              types = self.class::TYPES
              raise ArgumentError, "part type #{type.inspect} must be one of #{types.join(", ")}" unless types.include?(type)

              super
            end
          end
  end
end
