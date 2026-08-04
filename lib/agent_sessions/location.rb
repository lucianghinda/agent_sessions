# frozen_string_literal: true

module AgentSessions
  Location = Data.define(:kind, :path, :format, :glob) do
    def exists? = File.exist?(path)

    def matches
      glob ? Dir.glob(File.join(path, glob)) : []
    end
  end
end
