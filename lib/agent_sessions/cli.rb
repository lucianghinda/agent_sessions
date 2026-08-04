# frozen_string_literal: true

require "optparse"

module AgentSessions
  class CLI
    STATUS_MARKS = { pass: "✓", fail: "✗", drift: "~", skip: "-" }.freeze

    def initialize(argv, env: ENV, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @env = env
      @stdout = stdout
      @stderr = stderr
    end

    def run
      case @argv.shift
      when "where" then where
      when "doctor" then doctor
      when "audit" then audit
      when "version", "--version", "-v" then version
      when nil, "help", "--help", "-h" then help(@stdout, 0)
      else help(@stderr, 1)
      end
    # Catches UnknownAgent for a typo'd agent, and the declaration errors an
    # adapter raises when it is misconfigured. Layer 1 never raises for disk
    # state, so anything arriving here is worth one clean line, not a backtrace.
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
          doctor [AGENT]   verify on-disk layout against the adapter's claims
          audit            bytes per store and sync/backup exposure
          version          print version

        Options:
          --json           machine-readable output (every command)
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
      else value
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
