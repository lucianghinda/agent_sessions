# frozen_string_literal: true

module AgentSessions
  module Adapters
    class Pi < Base
      agent :pi
      label "pi"
      documented true
      verified_on "2026-07-21"

      fidelity :full

      base_dir default: "~/.pi/agent", env: "PI_CODING_AGENT_DIR"

      store :sessions, dir: "sessions", glob: "--*--/*.jsonl", format: :jsonl,
                       env: "PI_CODING_AGENT_SESSION_DIR"

      FILENAME = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})_(\h{8})\.jsonl\z/

      def session_id_from(path)
        captures = FILENAME.match(File.basename(path))&.captures or return super

        captures.last
      end

      # The rescue is not optional. \d{2} accepts 00-99, and Time.new raises
      # ArgumentError on month 13, minute 60 and friends. build_session scopes its
      # own rescue to File.stat so that a raising hook surfaces as the adapter bug
      # it usually is — but this hook raises on FILE DATA, and without the rescue
      # one malformed filename returns zero sessions from `sessions`,
      # `project_paths` and `for_project` alike, and exits the CLI with a raw
      # backtrace that takes every other agent's rows with it. Measured in Task 4.
      def started_at_for(path, stat)
        parts = FILENAME.match(File.basename(path))&.captures or return super

        begin
          Time.new(*parts.first(6).map(&:to_i))
        rescue ArgumentError # the digits matched but do not form a real date
          super
        end
      end

      # Same lossy dash rule as Claude, wrapped in double dashes:
      # /Users/you/app -> --Users-you-app-- (design doc section 7).
      # Expects an absolute, expanded path; sessions_for_project expands first.
      def encode_project(dir)
        "-#{dir.gsub(/[^a-zA-Z0-9]/, "-")}--"
      end

      # pi publishes its format: one header line, then typed entries (design doc
      # 8.6). The cwd key in that header is UNVERIFIED on a real session as of
      # 2026-08-05 — this machine has none. Verify when one exists.
      #
      # The predicate is mandatory, not decoration. scan_jsonl_for_key stops at the
      # first record merely CARRYING the key, so without a value guard a record
      # holding "cwd": null shadows a later usable one permanently, and a non-String
      # cwd reaches project_paths' .uniq.sort and raises.
      def project_path_for(path)
        record = scan_jsonl_for_key(path, "cwd", limit: 3) { |r| r["cwd"].is_a?(String) }
        record&.[]("cwd")
      end
    end
  end
end
