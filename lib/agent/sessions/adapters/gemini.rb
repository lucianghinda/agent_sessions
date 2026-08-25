# frozen_string_literal: true

module Agent
  module Sessions
        module Adapters
          # Gemini CLI. Verified against a real store on this machine (2026-08-24):
          # 9 project directories, 12 chat files, 121 records.
          #
          # The store is keyed by an opaque project hash, not by an encoded path:
          # ~/.gemini/tmp/<projectHash>/chats/session-<UTC stamp>-<hex8>.json, with
          # a sibling logs.json holding a flat prompt log. Nothing anywhere under
          # the store names a working directory — grepping every JSON file in it for
          # cwd, workspace, projectPath, rootPath and directory found zero — which
          # is why project resolution below depends on a separate map file rather
          # than on decoding the hash.
          class Gemini < Base
            agent :gemini
            label "Gemini CLI"
            documented false
            verified_on "2026-08-24"
            fidelity :full

            def self.reader_class = Readers::Gemini

            base_dir default: "~/.gemini"

            store :chats, dir: "tmp", glob: "*/chats/session-*.json", format: :json
            store :projects, path: "projects.json", format: :json, optional: true

            warning "sessions are grouped by an opaque project hash; without ~/.gemini/projects.json " \
                    "this gem cannot say which directory a session belongs to"

            # The delta-log variant: tokentelemetry's parser of this same store
            # handles chats written as JSONL with a header line and `$set` deltas.
            # No such file exists here (zero .jsonl anywhere under the store), so
            # this adapter reads the verified .json spelling only — and says so
            # where a user with the other spelling will see it, rather than
            # silently enumerating nothing for half their sessions.
            def warnings
              list = super
              jsonl = Dir.glob(File.join(escape_glob(primary_layer.path), "*", "chats", "*.jsonl"))
              if jsonl.any?
                list << "#{jsonl.size} chat file(s) use the JSONL delta format, which this adapter does " \
                        "not read yet; those sessions are not enumerated"
              end
              list
            end

            # session-2025-11-29T20-08-b20947ab.json. The trailing hex is NOT a
            # session id: two files in the real store share d4abc9ce while being
            # different sessions, so the whole basename is the id — unique, stable,
            # and derivable without opening the file, which is what Layer 2 is for.
            # The agent's own sessionId lives inside the document and reaches a
            # caller through the reader.
            FILENAME = /\Asession-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-\h+\.json\z/

            # UTC, unlike Codex and pi, whose rollout filenames use the local clock.
            # Verified rather than assumed: four real filenames match their own
            # document's startTime to the minute when read as UTC (12-42 against
            # 2025-12-12T12:42:50.033Z), and would be three hours out as local time
            # on the machine this was written on.
            #
            # Minute precision only — the document's startTime carries seconds, but
            # reading it would cost a parse per session, and Layer 2 is stat-only.
            def started_at_for(path, stat)
              parts = FILENAME.match(File.basename(path))&.captures or return super

              begin
                Time.utc(*parts.map(&:to_i))
              rescue ArgumentError # digits that do not form a real date
                super
              end
            end

            # The store groups sessions under a hash of the project directory that
            # this gem cannot reverse: it is not a plain SHA-256 of the path (tested
            # directly against real directories), and the store records the path
            # nowhere else. ~/.gemini/projects.json is the map Gemini itself keeps —
            # when it exists, this reads it; when it does not, nil is the honest
            # answer and `projects` reports nothing rather than inventing a name
            # from the hash.
            def project_path_for(path)
              hash = project_dir_name(path)
              hash && project_map[hash]
            end

            # <base>/tmp/<projectHash>/chats/<file>.json — two levels up from the
            # file, not one, so Base's default (the immediate parent) would answer
            # "chats" for every session.
            def project_dir_name(path)
              File.basename(File.dirname(File.dirname(path)))
            end

            def encode_project(dir)
              project_map.key(dir) || super
            end

            def project_paths
              return [] unless primary_layer.exists?

              Dir.glob(File.join(escape_glob(primary_layer.path), "*", "chats", "session-*.json"))
                 .filter_map { |path| project_path_for(path) }.uniq.sort
            end

            private

            # projects.json maps a directory to its hash. Memoized per instance, and
            # inverted once here rather than scanned per session — a store with
            # hundreds of sessions would otherwise re-read the file for each.
            #
            # Shape unverified: this file does not exist on the machine this adapter
            # was written on. Both plausible spellings are accepted (a flat
            # path => hash map, and a nested one under "projects"), and anything
            # else yields an empty map, which degrades to the same nil
            # project_path a missing file gives.
            def project_map
              @project_map ||= begin
                layer = layer(:projects)
                raw = layer&.exists? ? read_json(layer.path) : {}
                raw = raw["projects"] if raw["projects"].is_a?(Hash)
                if raw.is_a?(Hash)
                  raw.each_with_object({}) do |(dir, hash), map|
                    map[hash] = dir if dir.is_a?(String) && hash.is_a?(String)
                  end
                else
                  {}
                end
              end
            end
          end
        end
  end
end
