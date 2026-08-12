# frozen_string_literal: true

require "json"
require "date"
require "uri"
require "time"

require_relative "agent_sessions/version"
require_relative "agent_sessions/errors"
require_relative "agent_sessions/env_override"
require_relative "agent_sessions/location"
require_relative "agent_sessions/store"
require_relative "agent_sessions/check"
require_relative "agent_sessions/session"
require_relative "agent_sessions/message"
require_relative "agent_sessions/home_expansion"
# Before base: Base's class body includes Enumeration.
require_relative "agent_sessions/adapters/enumeration"
require_relative "agent_sessions/adapters/base"
require_relative "agent_sessions/adapters/claude"
require_relative "agent_sessions/adapters/codex"
require_relative "agent_sessions/adapters/pi"
require_relative "agent_sessions/adapters/amp"
require_relative "agent_sessions/adapters/opencode"
require_relative "agent_sessions/adapters/cursor"
require_relative "agent_sessions/adapters/cursor_ide"
require_relative "agent_sessions/readers/base"
require_relative "agent_sessions/readers/codex"
require_relative "agent_sessions/readers/claude"
require_relative "agent_sessions/audit"

module AgentSessions
  STALE_AFTER_DAYS = 90

  class << self
    # Re-registering a name deliberately replaces it, so a consumer can ship a
    # corrected adapter for an agent whose layout moved before the gem catches up.
    def register(adapter_class)
      name = adapter_class.agent_name
      raise Error, "#{adapter_class.inspect} declares no agent name" if name.nil?

      registry[name] = adapter_class
    end

    def registry
      @registry ||= {}
    end

    def agents = registry.keys

    def locate(agent, env: ENV)
      adapter_for(agent).new(env: env).locate
    end

    def all(env: ENV)
      registry.keys.map { |agent| locate(agent, env: env) }
    end

    def installed(env: ENV)
      all(env: env).select(&:installed?)
    end

    # Lazy: consuming N sessions stats N files, never more. `since`, when given,
    # must be a Time (or anything Time#>= accepts) — comparing updated_at (always
    # a Time; every adapter populates it, from mtime or store metadata) against a
    # Date, Integer, or String raises ArgumentError("comparison of Time with ...
    # failed"), which already names the mistake, so no extra guard is added here.
    # That raise happens on enumeration, not on this call, because the filter
    # itself is lazy — `sessions(:x, since: bad).first(1)` can raise from inside
    # `first`, not from this line.
    # Raises MissingDependency or UnreadableStore for opencode under the same
    # conditions described on for_project below.
    def sessions(agent, env: ENV, since: nil)
      list = adapter_for(agent).new(env: env).sessions
      since ? list.select { |session| session.updated_at >= since } : list
    end

    # One project across every agent (or the agents: subset), lazily: adapters
    # earlier in the sweep satisfy `first(n)` without the later ones ever being
    # asked. Within one adapter, though, laziness cannot skip non-matching
    # sessions — sessions_for_project must still stat and check each candidate
    # to know it does not match, so an adapter with zero matches costs a full
    # scan of its store before the sweep moves on. True of the six Base-driven
    # adapters; opencode pushes the filter into SQL (WHERE directory = ?) and
    # stats nothing.
    #
    # Deliberately does NOT rescue MissingDependency or UnreadableStore: opencode
    # without the sqlite3 gem, or with a corrupt/locked database, raises. Since
    # `flat_map` is lazy, that raise surfaces only once enumeration reaches the
    # failing adapter — possibly after other agents' sessions have already been
    # yielded to the caller mid-iteration, and possibly not at all if `first(n)`
    # is satisfied first. Silently omitting an agent's sessions is this gem's
    # worst failure mode (design doc decision 11), so this method never trades
    # a raised, attributable error for a quietly incomplete list. A caller that
    # wants the sweep to survive one bad agent should rescue per call, e.g. by
    # driving `agents:` itself and catching around each adapter; a caller who
    # just wants to route around a known-bad agent can pass `agents:` naming
    # every registered agent except it. The CLI (Task 10) does the former,
    # turning the same exceptions into per-agent "skipped" lines instead of one
    # failed sweep. Note a rescue cannot resume this enumerator: re-calling each
    # after a raise re-raises from the same adapter. The only recovery is a
    # fresh call with a narrower `agents:`.
    # Adapters are resolved eagerly, so an unknown name in `agents:` raises here
    # rather than mid-sweep. The deferral above is about DATA conditions, where
    # the raise carries information about a store; a typo'd agent symbol is a
    # programmer error knowable before any I/O, and `agents: [:claude, :nope]`
    # otherwise hands back Claude's sessions and then crashes. Base#initialize
    # only stores @env, so constructing all seven up front costs nothing, and
    # the sweep stays lazy — first(n) still stops at the first matching adapter.
    def for_project(dir, env: ENV, agents: nil)
      dir = File.expand_path(dir)
      adapters = (agents || registry.keys).map { |name| adapter_for(name).new(env: env) }
      adapters.lazy.flat_map { |adapter| adapter.sessions_for_project(dir) }
    end

    # Eager, unlike sessions/for_project: project_paths already reads every
    # session to answer (design doc section 7 — the on-disk encodings are lossy,
    # so the recorded cwd is the only reliable source), sorts, and dedupes, so a
    # lazy return type here would promise a laziness the work underneath cannot
    # honor. Returns a plain, already-sorted Array.
    # Raises MissingDependency or UnreadableStore for opencode, as sessions does.
    def projects(agent, env: ENV)
      adapter_for(agent).new(env: env).project_paths
    end

    # Companion to `projects`/`project_paths`, which both exclude a session
    # whose project could not be resolved rather than counting it (design doc
    # section 7) — so "this agent genuinely records no projects" and "this
    # agent's project resolution is broken" read identically from the
    # outside. Three of seven adapters can legitimately return a nil
    # project_path (Amp threads with no `trees`, cursor_ide by design, pi
    # whenever its unverified header assumption is wrong); this counts it for
    # any of them, uniformly, using only the public `sessions` enumerator —
    # no adapter needs to know this exists. Eager and a second full sweep of
    # the store, same cost class as `projects` itself, so it is opt-in
    # (called by the CLI only under `list --project`, never under plain
    # `list`) rather than folded into `projects`' own return value, which is
    # a documented, tested plain Array and would otherwise need a shape
    # change to carry both numbers.
    # Raises MissingDependency or UnreadableStore for opencode, as sessions does.
    def unresolved_project_count(agent, env: ENV)
      adapter_for(agent).new(env: env).sessions.count { |session| session.project_path.nil? }
    end

    # Layer 3. Takes a Session (from `sessions`, `for_project`), not an agent
    # name, because reading is per-session — the adapter comes from the session
    # itself. Raises UnsupportedFormat for an agent with no reader yet, rather
    # than returning a reader that yields nothing: "this gem cannot read that
    # format" and "that session has no messages" must never look alike.
    #
    # include_events: true adds the agent's UI-level records to the stream where
    # an adapter has them. They are excluded by default because they are
    # bookkeeping, not conversation, and they outnumber real messages.
    def read(session, **options)
      klass = adapter_for(session.agent).reader_class
      unless klass
        raise UnsupportedFormat,
              "no reader for #{session.agent} yet; Session#fidelity says #{session.fidelity}"
      end

      klass.new(session, **options)
    end

    def verify(agent = nil, env: ENV)
      targets = agent ? [adapter_for(agent)] : registry.values
      targets.flat_map { |klass| klass.new(env: env).verify }
    end

    def doctor(agent = nil, env: ENV, today: Date.today)
      targets = agent ? [adapter_for(agent)] : registry.values
      staleness = targets.map do |klass|
        age = (today - klass.verified_on_date).to_i
        if age > STALE_AFTER_DAYS
          Check.new(agent: klass.agent_name, status: :drift, claim: "verified within #{STALE_AFTER_DAYS} days",
                    detail: "last verified #{klass.verified_on_date} (#{age} days ago)")
        else
          Check.new(agent: klass.agent_name, status: :pass, claim: "verified within #{STALE_AFTER_DAYS} days",
                    detail: "last verified #{klass.verified_on_date}")
        end
      end
      verify(agent, env: env) + staleness
    end

    def audit(env: ENV)
      Audit.new(all(env: env), env: env).report
    end

    private

    def adapter_for(agent)
      registry.fetch(agent) do
        raise UnknownAgent, "unknown agent: #{agent.inspect} (known: #{registry.keys.join(", ")})"
      end
    end
  end
end

AgentSessions.register(AgentSessions::Adapters::Claude)
AgentSessions.register(AgentSessions::Adapters::Codex)
AgentSessions.register(AgentSessions::Adapters::Pi)
AgentSessions.register(AgentSessions::Adapters::Amp)
AgentSessions.register(AgentSessions::Adapters::Opencode)
AgentSessions.register(AgentSessions::Adapters::Cursor)
AgentSessions.register(AgentSessions::Adapters::CursorIde)

# The oldest verified_on among the built-in adapters. A claim about somebody
# else's software is only as current as its weakest link, so this is the honest
# answer to "when was this last known to be true".
AgentSessions::VERIFIED_ON = AgentSessions.registry.values.map(&:verified_on_date).min
