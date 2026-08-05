# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Amp < Base
      agent :amp
      label "Amp CLI"
      documented :partly
      verified_on "2026-07-21"
      fidelity :messages

      base_dir default: "~/.local/share/amp", env: "XDG_DATA_HOME", env_join: "amp"

      store :threads, dir: "threads", glob: "T-*.json", format: :json
      # Design doc 8.4: Amp's local layout drifts between machines, so threads/ is the
      # one path stable enough that its absence is a real failure. secrets.json is
      # declared but optional: it is a credentials file rather than a transcript store,
      # and it does not exist until `amp login` runs, so a missing one says the user has
      # not authenticated, not that this adapter's claim about the layout is wrong.
      # It stays a layer so `audit` can still report a plaintext token file inside a
      # sync folder, which is the check that actually matters for it.
      store :secrets, path: "secrets.json", format: :json, optional: true

      warning "the server holds the canonical copy; local threads may be a partial mirror"

      # env.initial.trees[0].uri is a file:// URI naming the workspace root
      # (verified 2026-08-05 against the one real thread on this machine,
      # which carries exactly one tree). This parses the whole thread JSON,
      # which is why project_path is on-demand: enumeration itself never
      # pays this. Threads can reference several trees; the first is
      # reported and multi-root threads keep their first answer (nobody has
      # observed one yet, and Session#project_path is a single String, not a
      # list — reporting all roots would need a data-model change this task
      # does not make).
      #
      # started_at deliberately does NOT read `created` from this same JSON:
      # that would turn every session's stat-only listing into a content
      # read, not just project_path's already-deferred one, breaking the
      # stat-only guarantee `sessions` makes for every adapter (Base's class
      # comment on `sessions`). Base's stat.birthtime fallback stays in
      # effect, nil-on-Linux limitation and all (see rule 3). This would be
      # worth revisiting if a caller needed accurate started_at without
      # already touching project_path — nothing today does (Task 10 sorts by
      # updated_at, matching Codex's own note on the same trade-off).
      #
      # URI.parse, not `uri.delete_prefix("file://")`: the naive strip
      # mishandles the authority-component form `file://localhost/Users/...`
      # (it would leave a leading "localhost/" in the path), which
      # URI.parse's #path strips correctly by design. A malformed or
      # non-file URI is file DATA, not an adapter bug, so both the parse and
      # the percent-decode are rescued rather than allowed to propagate — an
      # unrescued raise here would take every agent's listing down with it,
      # the same failure mode rule 2 warns about.
      def project_path_for(path)
        uri = read_json(path).dig("env", "initial", "trees", 0, "uri")
        return nil unless uri.is_a?(String)

        parsed = URI.parse(uri)
        return nil unless parsed.scheme == "file"

        URI.decode_uri_component(parsed.path)
      rescue URI::InvalidURIError, ArgumentError
        nil
      end
    end
  end
end
