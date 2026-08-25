# frozen_string_literal: true

module Agent
  module Sessions
        # One resolved layer of an agent's store.
        #
        # A location is one of three shapes, and `files` answers each differently:
        #
        #   glob         a directory plus a pattern       -> the pattern's matches
        #   single_file  one file (a `path:` store)       -> itself, if it is there
        #   directory    a directory with no known shape  -> nothing, and enumerable? is false
        #
        # The third shape is a store whose internal layout this gem has not learned yet
        # (opencode's pre-1.2.0 storage/ tree, Cursor's acp-sessions/). It returns [] so a
        # caller sweeping every layer does not blow up, and answers enumerable? false so that
        # caller can tell "nothing here to enumerate" apart from "enumerated, found none".
        #
        # single_file comes from the adapter's store DSL: `path:` means one file, `dir:` means
        # a directory. Resolution used to discard that distinction, which made a Layer 2
        # enumerator written as layers.flat_map(&:files) silently skip history.jsonl,
        # session_index.jsonl and secrets.json — a missing-session bug, not a visible error.
        Location = Data.define(:kind, :path, :format, :glob, :single_file) do
          def initialize(kind:, path:, format:, glob: nil, single_file: false)
            super
          end

          def exists? = File.exist?(path)

          def enumerable? = single_file || !glob.nil?

          def files
            return exists? ? [path] : [] if single_file
            return [] unless glob

            Dir.glob(File.join(escaped_path, glob))
          rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
            []
          end

          private

          # Only the path is escaped, never the glob. A resolved path may legitimately
          # contain glob metacharacters (a project directory named "app [old]"), and
          # unescaped they would be read as syntax and silently match nothing.
          def escaped_path
            path.gsub(/[\\{}\[\]*?]/) { |char| "\\#{char}" }
          end
        end
  end
end
