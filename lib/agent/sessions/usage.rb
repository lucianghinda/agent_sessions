# frozen_string_literal: true

module Agent
  module Sessions
          # Token counts an agent reported, for one message or one whole session,
          # normalized to five DISJOINT buckets: `input` never includes what was read
          # from or written to cache, and `output` never includes `reasoning`. Agents
          # disagree here — Codex's input_tokens includes its cached_input_tokens,
          # Claude's does not (both verified against real stores on this machine,
          # 2026-08-24) — and a caller summing across agents needs one rule, not one
          # per agent. Readers do the subtraction; this object only holds the result.
          #
          # nil means "this format does not record that dimension", and it is load-
          # bearing: absence must never read as zero, for the same reason
          # Agent::Sessions.read raises on a format with no reader. `cost` is reported
          # by the agent or absent — never derived from a pricing table, which would
          # go stale in a gem and is a consumer's decision anyway.
          Usage = Data.define(:input, :output, :cache_read, :cache_creation, :reasoning, :cost) do
            def initialize(input: nil, output: nil, cache_read: nil, cache_creation: nil, reasoning: nil, cost: nil)
              super
            end

            # Sums dimension-wise, keeping the nil/zero distinction: nil + nil stays
            # nil ("neither side records this"), nil + n is n — one recorded value is
            # a real value, not a value plus an unknown, because per-message absence
            # under a format that does record the dimension means "none reported for
            # this message", the one place absence and zero do coincide.
            def +(other)
              self.class.new(input: sum(input, other.input), output: sum(output, other.output),
                             cache_read: sum(cache_read, other.cache_read),
                             cache_creation: sum(cache_creation, other.cache_creation),
                             reasoning: sum(reasoning, other.reasoning), cost: sum(cost, other.cost))
            end

            private

            def sum(mine, theirs)
              return theirs if mine.nil?
              return mine if theirs.nil?

              mine + theirs
            end
          end
  end
end
