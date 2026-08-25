# frozen_string_literal: true

module AgentSessions
  module Adapters
    # Qwen Code. PROVISIONAL: ~/.qwen does not exist on the machine this was
    # written on (2026-08-24), so every claim here comes from tokentelemetry's
    # working parser of the same store (resources/tokentelemetry,
    # backend/main.py section 4) rather than from observation — the same
    # standing the pi reader carries, and declared the same way.
    #
    # Qwen is a Gemini CLI fork that kept Gemini's directory layout and
    # adopted Anthropic's message shape, which is why its store looks like
    # ~/.gemini's while its records read like Claude's.
    class Qwen < Base
      agent :qwen
      label "Qwen Code"
      documented false
      verified_on "2026-08-24"
      fidelity :full

      def self.reader_class = Readers::Qwen

      base_dir default: "~/.qwen"

      store :chats, dir: "projects", glob: "*/chats/*.jsonl", format: :jsonl
      store :settings, path: "settings.json", format: :json, optional: true

      def warnings
        list = super
        if primary_layer.exists?
          list << "Qwen's store shape is unverified — no ~/.qwen existed on the machine this " \
                  "adapter was written on, so it follows tokentelemetry's parser of the same " \
                  "format. If sessions or projects look wrong, please open an issue with the " \
                  "first line of one chat file."
        end
        list
      end

      # Unlike Gemini's, the project directory is reported as a name this gem
      # cannot decode into a path, so the recorded cwd inside the file is the
      # only source — the same position Claude and pi are in. The predicate is
      # mandatory: scan_jsonl_for_key stops at the first record merely CARRYING
      # the key, so without it a record holding "cwd": null shadows a later
      # usable one permanently.
      def project_path_for(path)
        scan_jsonl_for_key(path, "cwd", limit: 25) { |record| record["cwd"].is_a?(String) }&.fetch("cwd")
      end
    end
  end
end
