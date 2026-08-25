# frozen_string_literal: true

module Agent
  module Sessions
          # A point where the agent replaced earlier turns with a summary. Not a
          # message: its own payload restates turns already yielded, so anyone counting
          # would count them twice. replaced_count is how many turns it stood in for.
          Compaction = Data.define(:at, :replaced_count, :raw)
  end
end
