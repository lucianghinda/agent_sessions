# frozen_string_literal: true

module AgentSessions
  class Error < StandardError; end
  class UnknownAgent < Error; end
  class MissingDependency < Error; end
  class UnreadableStore < Error; end
  class UnsupportedFormat < Error; end
end
