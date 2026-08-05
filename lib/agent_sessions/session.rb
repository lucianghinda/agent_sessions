# frozen_string_literal: true

module AgentSessions
  # One recorded conversation. Everything here comes from a stat or the store's
  # own metadata — except project_path, which may need to read inside the session
  # file (design doc section 7: the on-disk directory encodings are lossy, so the
  # recorded cwd inside the file is the only reliable source). It is computed on
  # first access and memoized, which is why this is a plain class rather than a
  # frozen Data: an instance is immutable except for that one memo.
  class Session
    UNRESOLVED = Object.new
    private_constant :UNRESOLVED

    attr_reader :agent, :id, :path, :started_at, :updated_at, :bytes, :format, :fidelity

    def initialize(agent:, id:, path:, started_at:, updated_at:, bytes:, format:, fidelity:,
                   project_path: UNRESOLVED, &project_path_resolver)
      @agent = agent
      @id = id
      @path = path
      @started_at = started_at
      @updated_at = updated_at
      @bytes = bytes
      @format = format
      @fidelity = fidelity
      @project_path = project_path
      @project_path_resolver = project_path_resolver
    end

    # Collision-free across a mixed-agent collection, where bare ids may repeat.
    def uid = "#{agent}:#{id}"

    def project_path
      return @project_path unless @project_path.equal?(UNRESOLVED)

      @project_path = @project_path_resolver&.call
    end

    # The honest full dump — includes project_path, so it forces that read.
    # Callers listing thousands of sessions should build their own slimmer rows.
    def to_h
      {
        agent: agent, id: id, uid: uid, path: path, project_path: project_path,
        started_at: started_at, updated_at: updated_at,
        bytes: bytes, format: format, fidelity: fidelity
      }
    end
  end
end
