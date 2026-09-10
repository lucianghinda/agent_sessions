# frozen_string_literal: true

module Agent
  module Sessions
          # One model response, grouped from however many records a format split it
          # across. Claude Code writes one record PER CONTENT BLOCK of an API
          # response: in one real transcript on this machine, 260 assistant records
          # share only 124 message.id values, so a caller counting records over-
          # counts what the session actually did by roughly two to one. A round
          # trip is the unit that actually happened.
          #
          # `recorded` is the load-bearing field. False means this group was
          # ASSUMED — the format names no round-trip id, so grouping fell back to
          # one message per round trip — never "this session has none". Same rule
          # tree()/branching? already enforce for parent links: "not recorded"
          # must never read as "recorded and empty".
          #
          # A round trip deliberately carries NO tool results: a result can arrive
          # long after its call, and grouping streams one record at a time, so
          # pairing a call with its eventual result is a separate, eager layer
          # (Agent::Sessions::Loop, landing next) rather than this one's job.
          RoundTrip = Data.define(:index, :messages, :usage, :recorded) do
            # Every part of every message, in file order.
            def parts = messages.flat_map(&:parts)

            # The :tool_use parts only, [] when this round trip asked for no tool.
            def calls = parts.select { |part| part.type == :tool_use }

            # The distinct roles in this group, in first-seen order.
            def roles = messages.map(&:role).uniq

            # The first recorded Time among the messages, or nil when none carried one.
            def at = messages.filter_map(&:at).first

            # The first recorded model String, or nil.
            def model = messages.filter_map(&:model).first
          end
  end
end
