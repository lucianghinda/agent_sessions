# frozen_string_literal: true

module Agent
  module Sessions
          # One tool call, paired with whatever answered it. The pairing is by
          # CALL ID, never by position — a model can have two calls in flight at
          # once, and pairing by position would match the wrong call to the wrong
          # result.
          #
          # result_bytes is nil, not 0, when nothing answered the call: an
          # unanswered call and a call answered with an empty body are different
          # facts, and defaulting the body to "" would report a 0-byte answer for
          # a call that was never answered.
          #
          # Only sizes are carried, never bodies — transcripts hold credentials
          # and customer data, and this gem has no redaction before milestone 0.5.
          ToolCall = Data.define(:name, :call_id, :input_bytes, :result_bytes, :asked_in, :answered_in) do
            def answered? = !result_bytes.nil?
          end
  end
end
