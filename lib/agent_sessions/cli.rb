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
      @skipped_agents = []
    end

    def run
      command = @argv.shift
      case command
      when "where" then where
      when "list" then list
      when "du" then du
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
      reject_positional_args!("list")

      rows = collect_sessions(options).sort_by(&:updated_at).reverse
      if options[:json]
        @stdout.puts JSON.pretty_generate(rows.map { |session| jsonable(session_row(session)) })
      else
        print_session_table(rows)
      end
      exit_code_honoring_skips
    end

    def du
      options = { json: false, by: "agent" }
      OptionParser.new do |opts|
        opts.banner = "Usage: agent-sessions du [--by agent|project] [--json]"
        opts.on("--by KIND", "Group by agent (default) or project") do |value|
          raise Error, "invalid --by #{value.inspect} (use agent or project)" unless %w[agent project].include?(value)

          options[:by] = value
        end
        opts.on("--json", "Output JSON") { options[:json] = true }
      end.permute!(@argv)
      reject_positional_args!("du")

      sessions = collect_sessions({})
      warn_zero_row_gated_agents(sessions)

      groups = if options[:by] == "project"
                 # The opt-in that pays for project reads: one bounded read per
                 # file-based session (decision 12 — plain `list` never pays
                 # this cost). opencode alone pays nothing extra here, since
                 # its project_path answers from a column its query already
                 # selected. A session whose project cannot be resolved groups
                 # under "(unknown)" rather than being dropped — three of
                 # seven adapters can legitimately return nil (Amp with no
                 # workspace tree, cursor_ide by design, pi if its unverified
                 # header assumption is wrong).
                 sessions.group_by { |session| session.project_path || "(unknown)" }
               else
                 sessions.group_by { |session| session.agent.to_s }
               end

      # known_bytes descending, count descending as the tiebreaker. Without
      # the second key, every all-unknown group (known_bytes 0 — opencode's
      # 359 real sessions on this machine, entirely nil bytes) ties with any
      # other all-unknown group and falls back to group_by's insertion order,
      # which is registration order, not anything about the data. The
      # tiebreaker at least puts the biggest all-unknown group first among
      # its unknown peers, rather than leaving it to accident.
      rows = groups.map { |name, group| du_row(name, group) }
                   .sort_by { |row| [-row.fetch(:known_bytes), -row.fetch(:count)] }
      if options[:json]
        payload = rows.map do |row|
          { group: row[:group], sessions: row[:count],
            bytes: row[:unknown] == row[:count] ? nil : row[:known_bytes],
            unknown_sessions: row[:unknown] }
        end
        # Every other JSON-emitting command (list, where, doctor, audit)
        # funnels through jsonable; this one is `group:`, a recorded cwd
        # under --by project, was going straight to JSON.pretty_generate and
        # crashing on the first invalid-UTF-8 path. jsonable's Hash branch is
        # transform_values, so this covers group: (and sessions/bytes/
        # unknown_sessions, unaffected since they are not Strings) the same
        # way emit_json covers every other command's payload.
        @stdout.puts JSON.pretty_generate(payload.map { |row| jsonable(row) })
      else
        print_du_table(rows, sessions)
      end
      exit_code_honoring_skips
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
      # JSON.parse happily hands back a String carrying invalid UTF-8 (a raw
      # \xFF in a session log, say), and JSON.generate then raises
      # JSON::GeneratorError on it — not an AgentSessions::Error, so it
      # escapes `run`'s rescue and takes the whole command down with a raw
      # backtrace over one malformed file. du --by project is the first path
      # that puts a recorded cwd straight into a JSON value (list omits
      # project_path entirely — decision 12), which is what makes this
      # reachable today. A no-op for the well-formed data every other value
      # here already is.
      when String then value.scrub("?")
      else value
      end
    end

    SINCE_UNITS = { "h" => 3600, "d" => 86_400, "w" => 604_800 }.freeze

    # One agent's missing dependency or unreadable store must not silently empty
    # a cross-agent listing — each skip is announced on stderr, tracked in
    # @skipped_agents so the command can exit non-zero, and the rest still
    # print. The exit code matters as much as the stderr line: `--json` is the
    # door built for a machine consumer (design doc section 12), and a machine
    # reading `[]` next to exit 0 has no way to tell "empty store" from
    # "store I couldn't read" — the skip notice lives on stderr, which a
    # machine consumer of stdout JSON has every reason to discard. Decision 11
    # calls silent under-reporting this gem's worst failure mode; a truthful
    # message nobody who needs it ever sees is a milder version of the same
    # failure. UnreadableStore became reachable here in Task 8: opencode
    # raises it for a corrupt database, a non-writable store directory, or a
    # writer stuck past busy_timeout, and without this clause one of those
    # costs the user the other six agents' rows.
    #
    # `list` always sorts newest-first, so the whole matching set must be
    # materialized before anything can print, no matter how lazy the pipeline
    # underneath is — sorting is what forces that, not .force. The separate,
    # real cost is STAT COUNT, not laziness: for the six file-based adapters,
    # even a narrow --since window still stats every file in the store,
    # because updated_at can only be learned by stating it (nothing here
    # pushes the window into the adapter, though Codex's date-partitioned
    # directories are a structural hint that could). opencode is the
    # exception, and in the OTHER direction from what an early draft of this
    # comment claimed: it never stats a file — it answers from a SQL query —
    # so it pays no per-session stat cost regardless of --since; `since:`
    # below just filters whatever the query already returned, in Ruby, not in
    # a WHERE clause. Measured against this machine's real stores: the full
    # `list` sweep across all seven agents (~900 real sessions) is 0.021s, so
    # none of this is worth adapter-level plumbing yet. Revisit if a store
    # grows enough to change that.
    #
    # The non-project path delegates to AgentSessions.sessions(since:), which
    # already implements and documents this exact >=-inclusive comparison —
    # duplicating it here would let the two drift. The --project path can't
    # reuse it (for_project takes no since:), so it filters inline; both
    # express the identical comparison, just through different plumbing.
    #
    # Plan follow-up 9 ("a one-line stderr note when a gated-warning agent
    # contributes zero rows would put the message where the symptom is —
    # decide in Task 10") is considered here and deferred to Task 11's `du`.
    # Six of seven adapters' warnings name the symptom as "projects or
    # du --by project report nothing", which is du's territory, not list's.
    # Surfacing it also needs a fact list doesn't otherwise fetch — whether
    # the store is INSTALLED at all (Store#installed?, via locate()) versus
    # installed-but-warned-and-genuinely-empty, since zero rows from an agent
    # nobody has ever used is not a symptom worth a line. Doing that lookup
    # here would mean doing it again once Task 11 lands its own version.
    def collect_sessions(options)
      agents = options[:agent] ? [options[:agent]] : AgentSessions.agents
      agents.flat_map do |agent|
        scoped = if options[:project]
                   sessions = AgentSessions.for_project(options[:project], env: @env, agents: [agent])
                   options[:since] ? sessions.select { |session| session.updated_at >= options[:since] } : sessions
                 else
                   AgentSessions.sessions(agent, env: @env, since: options[:since])
                 end
        scoped.force
      rescue MissingDependency, UnreadableStore => e
        @skipped_agents << agent
        @stderr.puts "#{agent}: skipped (#{e.message})"
        []
      end
    end

    # Shared by list and du (Task 11), both of which call collect_sessions:
    # a skip must flip the exit code even though the rest of the output still
    # printed successfully. One list, not a list plus a boolean that mirrors
    # it: two variables recording the same fact (an earlier draft had
    # @agents_skipped alongside @skipped_agents) are one rename away from
    # silently disagreeing, which is exactly the failure mode decision 11a
    # exists to prevent.
    def exit_code_honoring_skips
      @skipped_agents.empty? ? 0 : 1
    end

    # `list claude` looks like it worked: it silently lists every agent's
    # sessions instead of erroring on the typo, because list takes no bare
    # positional (decision 10 — three filters need names) while where and
    # doctor take exactly one. That similarity is what makes the typo
    # tempting to type. du (Task 11) takes the same flags-only shape, so this
    # check is shared rather than inlined into list alone.
    def reject_positional_args!(command)
      return if @argv.empty?

      raise Error, "#{command}: unexpected argument #{@argv.first.inspect} (this command takes flags only)"
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

    # Cap the id column. Cursor's ids are two nested uuids joined by "/" (36 +
    # 1 + 36 = 73 chars) where every other agent needs a bare uuid (36) or
    # less, so one Cursor row makes the global id_width 73 — padding every
    # other row with ~35 spaces and pushing the line past 100 chars, which
    # wraps on an 80-column terminal. Elide the middle and keep both ends,
    # since the ends are what a human matches against a directory name.
    ID_COLUMN_MAX = 38

    # Group names in `du --by project` are the same shape of problem one cap
    # wider: a real project path on this machine ran 169 characters, wrapping
    # every row across three lines on an 80-column terminal (list's own id
    # column tops out at 72 total). Wider than ID_COLUMN_MAX because a path's
    # head (which user, which drive) and tail (the actual project directory)
    # are both worth keeping, and both need more room than a bare uuid does.
    GROUP_COLUMN_MAX = 60

    def elide(text, max = ID_COLUMN_MAX)
      return text if text.length <= max

      keep = (max - 1) / 2
      "#{text[0, keep]}…#{text[-keep..]}"
    end

    def print_session_table(rows)
      return if rows.empty?

      agent_width = rows.map { |session| session.agent.to_s.length }.max
      id_width = rows.map { |session| elide(session.id).length }.max
      size_cells = rows.map { |session| bytes_cell(session.bytes) }
      size_width = size_cells.map(&:length).max
      rows.each_with_index do |session, index|
        @stdout.puts [
          session.agent.to_s.ljust(agent_width),
          elide(session.id).ljust(id_width),
          session.updated_at.strftime("%Y-%m-%d %H:%M"),
          size_cells[index].rjust(size_width)
        ].join("  ")
      end
    end

    # opencode sessions are rows in a shared database, not standalone files, so
    # their size is not a file size and nil means unknown, not zero.
    def bytes_cell(bytes)
      bytes.nil? ? "?" : human_bytes(bytes)
    end

    def du_row(name, group)
      { group: name, count: group.size,
        known_bytes: group.sum { |session| session.bytes || 0 },
        unknown: group.count { |session| session.bytes.nil? } }
    end

    def print_du_table(rows, sessions)
      return if rows.empty?

      all_rows = rows + [du_row("TOTAL", sessions)]
      # Elided for display only — the underlying row[:group] (and the JSON
      # payload built from the same rows) keeps the full, unelided path.
      display_names = all_rows.map { |row| elide(row[:group], GROUP_COLUMN_MAX) }
      name_width = display_names.map(&:length).max
      count_width = all_rows.map { |row| row[:count].to_s.length }.max
      size_cells = all_rows.map { |row| du_bytes_cell(row) }
      size_width = size_cells.map(&:length).max
      all_rows.each_with_index do |row, index|
        @stdout.puts [
          display_names[index].ljust(name_width),
          row[:count].to_s.rjust(count_width),
          size_cells[index].rjust(size_width)
        ].join("  ")
      end
    end

    # All sizes in the group unknown -> "?" (never a silently-short zero, per
    # decision 7 — opencode's bytes are nil for all 359 real sessions on this
    # machine, and a bare "0 B" would look like a real, tiny answer instead of
    # "cannot know"). Some unknown -> a trailing "+" on the known total, since
    # it is real but incomplete. All known -> the plain number.
    #
    # The "+" says "incomplete" but not "by how much" — deliberate. The text
    # table stays a one-glance summary; a consumer that needs the exact gap
    # already has --json, whose payload carries unknown_sessions per row.
    #
    # The plan's own sketch of this guarded the "?" branch with
    # row[:count].positive? too. Dropped here, disclosed rather than silently
    # omitted: du_row's `count` is a group's own group_by size, which
    # group_by never returns as zero, so that guard cannot be false in
    # practice. Kept out rather than kept "just in case" — a condition
    # nothing can make false is a claim about a guarantee elsewhere, not a
    # check this method needs to make itself.
    def du_bytes_cell(row)
      return "?" if row[:unknown] == row[:count]

      cell = human_bytes(row[:known_bytes])
      row[:unknown].positive? ? "#{cell}+" : cell
    end

    # Plan follow-up 9, decided here rather than left open a second time (the
    # Task 10 review deferred it to du's territory: every gated warning across
    # pi/amp/cursor/cursor_ide names its own symptom as "projects or
    # du --by project report nothing", which is this command, not list's).
    # Fires only for an agent whose store is actually installed
    # (Store#installed?) and carries at least one warning — a never-used
    # agent (the common case for pi/cursor/cursor_ide on most machines) stays
    # silent, since zero rows from an agent nobody has ever used is not a
    # symptom worth a line. Also skips any agent collect_sessions already
    # reported skipped above, whose stderr line already explains the zero
    # rows for a different, already-visible reason.
    #
    # Deliberately does NOT flip the exit code the way a skip does (decision
    # 11a): a skip means the printed total is silently WRONG (an agent's
    # bytes are simply missing from it), which is the failure decision 11a
    # exists to catch. A warned-but-empty agent's total is still RIGHT — it
    # correctly reports zero for that agent — merely unexplained without this
    # line. Exit 0 says the numbers are trustworthy; the stderr line is a
    # pointer to more context, not a correction to them.
    def warn_zero_row_gated_agents(sessions)
      reporting = sessions.map(&:agent).uniq
      (AgentSessions.agents - @skipped_agents - reporting).each do |agent|
        store = AgentSessions.locate(agent, env: @env)
        next unless store.installed? && !store.warnings.empty?

        @stderr.puts "#{agent}: installed but contributed 0 sessions here — " \
                     "run `agent-sessions where #{agent}` to see why (#{store.warnings.size} warning(s))"
      end
    end

    def human_bytes(bytes)
      return "0 B" if bytes.zero?

      exp = (Math.log(bytes) / Math.log(1024)).floor.clamp(0, 4)
      return "#{bytes} B" if exp.zero?

      format("%.1f %s", bytes.to_f / (1024**exp), %w[B KB MB GB TB][exp])
    end
  end
end
