# frozen_string_literal: true

module Agent
  module Sessions
          # One message in a branching conversation, with the messages that follow it.
          # Agents that let a turn be edited and re-run record two children under one
          # parent: 380 such branch points sit across 85 of 151 real Claude transcripts,
          # so a caller reading `messages` in file order is reading two alternative
          # histories interleaved without being told.
          #
          # children is a plain Array and the Node is frozen, so the shape is settled
          # before anyone sees it.
          Node = Data.define(:message, :children)
  end
end
