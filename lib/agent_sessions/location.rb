# frozen_string_literal: true

module AgentSessions
  Location = Data.define(:kind, :path, :format, :glob) do
    def exists? = File.exist?(path)

    # Expands this location's glob and nothing else. Glob-less locations
    # return [] even though they may be a single file or a whole directory.
    def matches
      return [] unless glob

      Dir.glob(File.join(escaped_path, glob))
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      []
    end

    private

    # Only the path is escaped, never the glob. A resolved path may legitimately
    # contain glob metacharacters (a project directory named "app [old]"), and
    # unescaped they would be read as syntax and silently match nothing.
    def escaped_path
      path.gsub(/[\\{}\[\]*?]/) { |char| "\\#{char}" }
    end
  end
end
