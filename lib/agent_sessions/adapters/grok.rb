# frozen_string_literal: true

module AgentSessions
  module Adapters
    # Grok Build (xAI). PROVISIONAL: ~/.grok does not exist on the machine
    # this was written on (2026-08-24), so every claim follows
    # tokentelemetry's working parser of the same store
    # (resources/tokentelemetry, _scan_grok_sessions and
    # _grok_usage_from_unified_log) rather than observation.
    #
    # A Grok session is a DIRECTORY, not a file:
    #   ~/.grok/sessions/<url-encoded cwd>/<session-uuid>/
    #     summary.json  chat_history.jsonl  events.jsonl  updates.jsonl
    #     signals.json  plan_mode.json  subagents/<spawn-id>/meta.json
    #
    # summary.json is what this adapter enumerates, because it is the record
    # that always exists and carries the session's own metadata. The
    # transcript beside it is what the reader reads, and `bytes` counts the
    # whole directory — the same choice Claude's adapter makes for its
    # sidecar tree, and for the same reason: those bytes belong to this
    # session, and a `du` that ignored them would disagree with the disk.
    class Grok < Base
      agent :grok
      label "Grok Build"
      documented false
      verified_on "2026-08-24"
      fidelity :full

      def self.reader_class = Readers::Grok

      base_dir default: "~/.grok"

      store :sessions, dir: "sessions", glob: "*/*/summary.json", format: :json
      store :unified_log, path: File.join("logs", "unified.jsonl"), format: :jsonl, optional: true

      warning "billed token usage is not in the session directory: it lives in " \
              "~/.grok/logs/unified.jsonl, keyed by session id, and is unavailable if that " \
              "log has rotated away"

      def warnings
        list = super
        if primary_layer.exists?
          list << "Grok's store shape is unverified — no ~/.grok existed on the machine this " \
                  "adapter was written on, so it follows tokentelemetry's parser of the same " \
                  "format. Please open an issue if sessions, projects or usage look wrong."
        end
        list
      end

      # <sessions>/<url-encoded cwd>/<session-uuid>/summary.json — the id is
      # the directory holding the file, not the file's own basename, which is
      # the constant "summary".
      def session_id_from(path)
        File.basename(File.dirname(path))
      end

      # The project bucket is a URL-encoded absolute path (tokentelemetry
      # unquotes it), so unlike Claude's and pi's dash encodings this one is
      # losslessly reversible. summary.json's own info.cwd is preferred where
      # readable, because a recorded path beats a decoded directory name; the
      # decode is the fallback, and a good one.
      def project_path_for(path)
        recorded = read_json(path).dig("info", "cwd")
        return recorded if recorded.is_a?(String)

        decode_project(File.basename(File.dirname(File.dirname(path))))
      end

      def project_dir_name(path)
        File.basename(File.dirname(File.dirname(path)))
      end

      def encode_project(dir)
        # Percent-encode everything a path separator is not, matching what
        # URL-encoding a whole path produces. CGI.escape is deliberately not
        # used: it encodes a space as "+", which decodes back to "+" here.
        URI.encode_www_form_component(dir).gsub("+", "%20")
      end

      def decode_project(name)
        URI.decode_www_form_component(name)
      rescue ArgumentError # a name that is not valid percent-encoding
        name
      end

      # summary.json carries the session's own clock; the file's mtime is only
      # ever a proxy for it. Both are ISO 8601 strings per the reference
      # parser, with created_at standing in when updated_at is absent.
      def started_at_for(path, stat)
        parse_time(read_json(path)["created_at"]) || super
      end

      def updated_at_for(path, stat)
        summary = read_json(path)
        parse_time(summary["updated_at"]) || parse_time(summary["created_at"]) || super
      end

      # The whole session directory, not just summary.json: the transcript and
      # every sibling log live in it.
      def bytes_for(path, stat)
        dir = File.dirname(path)
        Dir.glob(File.join(escape_glob(dir), "**", "*"), File::FNM_DOTMATCH).sum do |entry|
          File.file?(entry) ? File.size(entry) : 0
        rescue SystemCallError
          0
        end
      end

      private

      def parse_time(value)
        return nil unless value.is_a?(String)

        Time.iso8601(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
