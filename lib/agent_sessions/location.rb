# frozen_string_literal: true

module AgentSessions
  Location = Data.define(:kind, :path, :format, :glob) do
    def exists? = File.exist?(path)

    # Expands this location's glob and nothing else. Glob-less locations
    # return [] even though they may be a single file or a whole directory.
    def matches
      glob ? Dir.glob(File.join(path, glob)) : []
    end
  end
end
