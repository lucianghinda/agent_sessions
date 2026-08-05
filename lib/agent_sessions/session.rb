# frozen_string_literal: true

module AgentSessions
  # One recorded conversation. Everything here comes from a stat or the store's
  # own metadata — except project_path, which may need to read inside the session
  # file (design doc section 7: the on-disk directory encodings are lossy, so the
  # recorded cwd inside the file is the only reliable source). It is computed on
  # first access and memoized, which is why this is a plain class rather than a
  # frozen Data: an instance is immutable except for that one memo.
  #
  # Equality is identity, not value — unlike every sibling value object here, which
  # gets value equality for free from Data. A value comparison would have to force
  # project_path on both operands, turning a `uniq` over thousands of sessions into
  # the full content sweep the design works to avoid. A caller keying a mixed-agent
  # collection should use `uid`, which exists for exactly that. Note `to_h` includes
  # `uid`, so its output does not round-trip back through `new`.
  class Session
    UNRESOLVED = Object.new.freeze
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

    # A resolver that raises is deliberately not memoized: a failed read is not an
    # answer, so the next call retries rather than freezing the failure in place.
    #
    # Not thread-safe by design: concurrent first access can run the resolver more
    # than once, but every run yields the same value and the assignment is atomic
    # on MRI, so there is no torn read to guard against. Do not add a mutex.
    def project_path
      return @project_path unless @project_path.equal?(UNRESOLVED)

      @project_path = @project_path_resolver&.call
      @project_path_resolver = nil
      @project_path
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

    # Never calls project_path: inspecting a session in a debugger must not
    # trigger the read that enumeration deliberately deferred.
    def inspect
      resolved = @project_path.equal?(UNRESOLVED) ? "(unresolved)" : @project_path.inspect
      "#<#{self.class.name} agent: #{agent.inspect}, id: #{id.inspect}, path: #{path.inspect}, " \
        "project_path: #{resolved}, started_at: #{started_at.inspect}, updated_at: #{updated_at.inspect}, " \
        "bytes: #{bytes.inspect}, format: #{format.inspect}, fidelity: #{fidelity.inspect}>"
    end
  end
end
