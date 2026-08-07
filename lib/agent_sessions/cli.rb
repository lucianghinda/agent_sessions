# frozen_string_literal: true

require "optparse"
require "time"

module AgentSessions
  class CLI
    STATUS_MARKS = { pass: "✓", fail: "✗", drift: "~", skip: "-" }.freeze

    def initialize(argv, env: ENV, stdout: $stdout, stderr: $stderr, now: Time.now)
      @argv = argv.dup
      @env = env
      @stdout = stdout
      @stderr = stderr
      @now = now
    end

    def run
      command = @argv.shift
      case command
      when "where" then where
      when "list" then list
      when "doctor" then doctor
      when "audit" then audit
      when "version", "--version", "-v" then version
      when nil, "help", "--help", "-h" then help(@stdout, 0)
      else
        @stderr.puts "unknown command: #{command}"
        help(@stderr, 1)
      end
    # Catches UnknownAgent for a typo'd agent, the declaration errors an
    # adapter raises when it is misconfigured, and — since Task 8 —
    # MissingDependency (opencode's sqlite3 gem missing) and UnreadableStore
    # (opencode's database present but unreadable), both AgentSessions::Error
    # subclasses. "Layer 1 never raises for disk state" was true before
    # Layer 2 existed; it is not anymore — opencode's Layer 2 raises both
    # deliberately (design doc section 9). `list` (Task 10) is the first
    # command that walks Layer 2, and it does NOT rely on this rescue for
    # that case — collect_sessions catches both per agent so one bad store
    # never empties the rest of the listing (decision 11). This broad catch
    # still matters for `list`'s own option parsing (a malformed --since is
    # an AgentSessions::Error) and stays here as the backstop for whichever
    # future command calls into Layer 2 without its own per-agent rescue.
    rescue AgentSessions::Error, OptionParser::ParseError => e
      @stderr.puts e.message
      1
    end

    private

    def where
      json = parse_json_flag("where [AGENT] [--json]")
      agent = @argv.shift&.to_sym
      stores = agent ? [AgentSessions.locate(agent, env: @env)] : AgentSessions.all(env: @env)
      if json
        emit_json(stores)
      else
        stores.each { |store| print_store(store) }
      end
      0
    end

    def doctor
      json = parse_json_flag("doctor [AGENT] [--json]")
      agent = @argv.shift&.to_sym
      checks = AgentSessions.doctor(agent, env: @env)
      if json
        emit_json(checks)
      else
        # doctor returns every agent's store checks followed by every agent's
        # staleness check, which for seven agents scatters one agent's answer
        # across two distant regions of the terminal. Group for reading; the
        # flat array stays as-is for --json consumers.
        checks.group_by(&:agent).each do |agent_name, agent_checks|
          @stdout.puts agent_name
          agent_checks.each do |check|
            @stdout.puts "  #{STATUS_MARKS.fetch(check.status)} #{check.claim}: #{check.detail}"
          end
        end
      end
      checks.any? { |c| c.status == :fail } ? 1 : 0
    end

    def list
      options = { json: false, agent: nil, project: nil, since: nil }
      OptionParser.new do |opts|
        opts.banner = "Usage: agent-sessions list [--agent X] [--project DIR] [--since 30d] [--json]"
        opts.on("--agent NAME", "Only this agent") { |value| options[:agent] = value.to_sym }
        opts.on("--project DIR", "Only sessions recorded in DIR") { |value| options[:project] = value }
        opts.on("--since DURATION", "Only sessions updated within DURATION (12h, 30d, 2w)") do |value|
          options[:since] = parse_since(value)
        end
        opts.on("--json", "Output JSON") { options[:json] = true }
      end.permute!(@argv)

      rows = collect_sessions(options).sort_by(&:updated_at).reverse
      if options[:json]
        @stdout.puts JSON.pretty_generate(rows.map { |session| jsonable(session_row(session)) })
      else
        print_session_table(rows)
      end
      0
    end

    def audit
      json = parse_json_flag("audit [--json]")
      findings = AgentSessions.audit(env: @env)
      if json
        emit_json(findings)
      else
        print_audit(findings)
      end
      0
    end

    def version
      @stdout.puts AgentSessions::VERSION
      0
    end

    def help(io, status)
      io.puts <<~USAGE
        Usage: agent-sessions COMMAND [options]

        Commands:
          where [AGENT]    resolved paths, env overrides, format, retention
          list             sessions, newest first (--agent, --project, --since)
          du               session disk usage (--by agent|project)
          doctor [AGENT]   verify on-disk layout against the adapter's claims
          audit            bytes per store and sync/backup exposure
          version          print version

        Options:
          --json           machine-readable output (where, list, du, doctor, audit)
      USAGE
      status
    end

    def parse_json_flag(banner)
      json = false
      OptionParser.new do |opts|
        opts.banner = "Usage: agent-sessions #{banner}"
        opts.on("--json", "Output JSON") { json = true }
      end.permute!(@argv)
      json
    end

    def print_store(store)
      installed = store.installed? ? "" : " (not installed)"
      @stdout.puts "#{store.label}#{installed}"
      store.layers.each do |location|
        @stdout.puts "  #{location.kind}: #{location.path} [#{location.format}]"
      end
      store.env_overrides.each do |override|
        state = override.active? ? "= #{override.value}" : "(not set)"
        @stdout.puts "  env: #{override.name} #{state}"
      end
      @stdout.puts "  retention: #{store.retention ? "#{store.retention} days" : "none"}"
      store.warnings.each { |warning| @stdout.puts "  warning: #{warning}" }
      @stdout.puts
    end

    def print_audit(findings)
      rows = findings.map { |finding| ["#{finding.agent}/#{finding.kind}", human_bytes(finding.bytes), finding] }
      label_width = rows.map { |label, _, _| label.length }.max || 0
      size_width = rows.map { |_, size, _| size.length }.max || 0

      rows.each do |label, size, finding|
        risk = finding.synced_to.any? ? "  SYNCED: #{finding.synced_to.join(", ")}" : ""
        @stdout.puts "#{label.ljust(label_width)}  #{size.rjust(size_width)}  #{finding.path}#{risk}"
      end

      at_risk = findings.select { |f| f.synced_to.any? }.sum(&:bytes)
      @stdout.puts "#{human_bytes(at_risk)} in synced locations"
    end

    def emit_json(records)
      @stdout.puts JSON.pretty_generate(records.map { |record| jsonable(record.to_h) })
    end

    def jsonable(value)
      case value
      when Hash then value.transform_values { |v| jsonable(v) }
      when Array then value.map { |v| jsonable(v) }
      when Data then jsonable(value.to_h)
      when Date then value.iso8601
      when Time then value.iso8601
      else value
      end
    end

    SINCE_UNITS = { "h" => 3600, "d" => 86_400, "w" => 604_800 }.freeze

    # One agent's missing dependency or unreadable store must not silently empty
    # a cross-agent listing — each skip is announced on stderr and the rest still
    # print. UnreadableStore became reachable here in Task 8: opencode raises it
    # for a corrupt database, a non-writable store directory, or a writer stuck
    # past busy_timeout, and without this clause one of those costs the user the
    # other six agents' rows.
    #
    # .force materializes each agent's full matching set before this method
    # returns, and applying --since here (rather than pushing it into the
    # adapter) means every session in the store still gets stat'd to learn its
    # updated_at even when the time window keeps almost none of them — measured
    # against this machine's real stores (see Task 10 report): ~360-session
    # Codex and opencode stores both filter in well under 50ms, so the cost is
    # real but not currently worth adapter-level plumbing. Revisit if a store
    # grows enough to make that untrue.
    def collect_sessions(options)
      agents = options[:agent] ? [options[:agent]] : AgentSessions.agents
      agents.flat_map do |agent|
        scoped = if options[:project]
                   AgentSessions.for_project(options[:project], env: @env, agents: [agent])
                 else
                   AgentSessions.sessions(agent, env: @env)
                 end
        scoped = scoped.select { |session| session.updated_at >= options[:since] } if options[:since]
        scoped.force
      rescue MissingDependency, UnreadableStore => e
        @stderr.puts "#{agent}: skipped (#{e.message})"
        []
      end
    end

    def parse_since(value)
      match = /\A(\d+)([hdw])\z/.match(value)
      raise Error, "invalid --since #{value.inspect} (use forms like 12h, 30d, 2w)" unless match

      @now - (match[1].to_i * SINCE_UNITS.fetch(match[2]))
    end

    # No project_path column: emitting it would force a content read per row,
    # turning a stat-only listing into a full sweep. du --by project opts in.
    def session_row(session)
      {
        agent: session.agent, id: session.id, uid: session.uid, path: session.path,
        started_at: session.started_at, updated_at: session.updated_at,
        bytes: session.bytes, format: session.format, fidelity: session.fidelity
      }
    end

    # Cap the id column. Cursor's ids are two nested uuids joined by "/", so one
    # Cursor row makes the global id_width 73 where every other agent needs 38 —
    # padding all their rows with ~35 spaces and pushing the line to 108 chars,
    # which wraps on an 80-column terminal. Elide the middle and keep both ends,
    # since the ends are what a human matches against a directory name.
    ID_COLUMN_MAX = 38

    def elide(id)
      return id if id.length <= ID_COLUMN_MAX

      keep = (ID_COLUMN_MAX - 1) / 2
      "#{id[0, keep]}…#{id[-keep..]}"
    end

    def print_session_table(rows)
      return if rows.empty?

      agent_width = rows.map { |session| session.agent.to_s.length }.max
      id_width = rows.map { |session| elide(session.id).length }.max
      rows.each do |session|
        @stdout.puts [
          session.agent.to_s.ljust(agent_width),
          elide(session.id).ljust(id_width),
          session.updated_at.strftime("%Y-%m-%d %H:%M"),
          bytes_cell(session.bytes)
        ].join("  ")
      end
    end

    # opencode sessions are rows in a shared database, not standalone files, so
    # their size is not a file size and nil means unknown, not zero.
    def bytes_cell(bytes)
      bytes.nil? ? "?" : human_bytes(bytes)
    end

    def human_bytes(bytes)
      return "0 B" if bytes.zero?

      exp = (Math.log(bytes) / Math.log(1024)).floor.clamp(0, 4)
      return "#{bytes} B" if exp.zero?

      format("%.1f %s", bytes.to_f / (1024**exp), %w[B KB MB GB TB][exp])
    end
  end
end
