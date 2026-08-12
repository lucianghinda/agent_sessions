# frozen_string_literal: true

module AgentSessions
  module Readers
    # Claude Code transcripts. Written against 142 real transcripts, 29,688
    # records, inventoried 2026-08-12.
    #
    # The content vocabulary is a straight match for this gem's: text, thinking,
    # tool_use, tool_result and image are exactly the five part types the design
    # doc names, so nothing here has to invent a mapping. What Claude adds is
    # everything *around* the conversation — a third of all records are session
    # state, and two more kinds carry context the model saw without being a turn
    # anyone took.
    class Claude < Base
      # State, not conversation, and together 11,000+ of the records written.
      # Skipped in silence: warning about a record deliberately classified would
      # teach a caller that warnings are noise.
      NON_MESSAGE_TYPES = %w[ai-title mode permission-mode agent-name last-prompt
                             file-history-snapshot file-history-delta queue-operation
                             pr-link summary].freeze

      # Context the model saw, but not a turn: `system` is turn_duration,
      # stop_hook_summary, away_summary, local_command; `attachment` is hook
      # output, skill listings, task reminders, pasted files. Same judgement
      # Codex's event_msg gets — available on request, never on by default.
      EVENT_TYPES = %w[system attachment].freeze

      CONTENT_PARTS = { "text" => :text, "thinking" => :thinking, "tool_use" => :tool_use,
                        "tool_result" => :tool_result, "image" => :image }.freeze

      # How Claude Code points at output too large to inline. It is prose, not a
      # structured field — 24 real tool_result parts and 149 attachments carry
      # this sentence — so the path has to be matched out of the text.
      SPILL = /Full output saved to:\s*(\S+)/

      # A spilled file is read whole. The largest observed is well under this;
      # the cap exists because the pointer says nothing about the size.
      MAX_SPILL_BYTES = 4_000_000

      def initialize(session, resolve_spills: true, **rest)
        super(session, **rest)
        @resolve_spills = resolve_spills
      end

      # The transcripts of agents this session spawned, as readers of their own.
      # Exposed rather than inlined, per design doc 8.1: a subagent's turns are
      # not the parent's turns, and merging them would break every count taken
      # from this reader. 124 of these sit beside real sessions on this machine.
      #
      # isSidechain is false on all 22,072 records in the main transcripts, so
      # there is nothing to filter out there — the separation is already how
      # Claude Code writes them.
      def subagents
        entries = begin
          Dir.children(File.join(sidecar_root, "subagents"))
        rescue SystemCallError
          return []
        end

        entries.sort.filter_map do |name|
          next unless File.extname(name) == ".jsonl"

          child = child_session(File.join(sidecar_root, "subagents", name))
          child && self.class.new(child, resolve_spills: @resolve_spills, include_events: include_events)
        end
      end

      private

      attr_reader :resolve_spills

      def message_for(record, line_number)
        type = record["type"]
        return nil if NON_MESSAGE_TYPES.include?(type)
        return event_message(record, type) if EVENT_TYPES.include?(type)

        unless %w[user assistant].include?(type)
          warn_about("line #{line_number}: unrecognized record type #{type.inspect}")
          return build(record, :unknown, [Part.new(type: :unknown)])
        end

        build(record, type.to_sym, content_parts(record, line_number))
      end

      # content is an Array of parts in 17,408 real messages and a bare String
      # in 636. The String spelling is the same thing said shorter.
      def content_parts(record, line_number)
        content = record.dig("message", "content")
        return [Part.new(type: :text, text: content)] if content.is_a?(String)

        Array(content).map { |item| part_for(item, line_number) }
      end

      def part_for(item, line_number)
        return Part.new(type: :unknown) unless item.is_a?(Hash)

        case CONTENT_PARTS[item["type"]]
        when :text then Part.new(type: :text, text: item["text"].to_s)
        when :thinking then Part.new(type: :thinking, text: item["thinking"].to_s)
        when :image then Part.new(type: :image)
        when :tool_use
          Part.new(type: :tool_use, name: item["name"], call_id: item["id"],
                   text: stringify(item["input"]))
        when :tool_result
          Part.new(type: :tool_result, call_id: item["tool_use_id"],
                   text: spilled(flatten_result(item["content"])))
        else
          warn_about("line #{line_number}: unrecognized content part #{item["type"].inspect}")
          Part.new(type: :unknown, text: item["text"])
        end
      end

      # A tool_result's content is a String, or an array of parts the same shape
      # as a message's. Only its text is kept here; raw holds the rest.
      def flatten_result(content)
        return content if content.is_a?(String)

        Array(content).filter_map { |item| item["text"] if item.is_a?(Hash) && item["type"] == "text" }.join
      end

      def event_message(record, type)
        return nil unless include_events

        label = type == "system" ? record["subtype"] : record.dig("attachment", "type")
        build(record, :system, [Part.new(type: :unknown, text: label)])
      end

      def build(record, role, parts)
        Message.new(role: role, at: time_from(record["timestamp"]), parts: parts, raw: record)
      end

      def stringify(value)
        value.is_a?(String) || value.nil? ? value.to_s : JSON.generate(value)
      end

      # Replaces "Output too large … Full output saved to: <path>" with what the
      # file actually holds, so a :tool_result carries content rather than a
      # pointer (design doc 8.1).
      #
      # The path is read out of tool output, which is untrusted: a transcript
      # can say anything, including that its spill lives in /etc/passwd or in
      # another project's directory. Resolving it blindly would turn this reader
      # into a file-read primitive driven by content. Only the session's own
      # sidecar directory is readable, checked before the path is opened and
      # again through realpath so a symlink inside it cannot lead out.
      def spilled(text)
        return text unless resolve_spills && text.is_a?(String)

        path = text[SPILL, 1]
        return text unless path

        candidate = File.expand_path(path)
        unless readable_spill?(candidate)
          return warn_about("spill path is outside this session's sidecar tree " \
                            "and was not read: #{path}") || text
        end

        read_spill(candidate) || text
      end

      # The trees a spill may legitimately live in. Own sidecar always; plus the
      # enclosing one when this transcript is itself a subagent, because a
      # subagent has no sidecar of its own — its oversized output spills to
      # <parent-id>/tool-results/. Running this over 124 real subagent
      # transcripts is what found that; a boundary drawn at the subagent's own
      # id refused every spill they reference.
      def spill_roots
        @spill_roots ||= begin
          roots = [sidecar_root]
          roots << File.dirname(File.dirname(session.path)) if subagent_transcript?
          roots
        end
      end

      def subagent_transcript? = File.basename(File.dirname(session.path)) == "subagents"

      def readable_spill?(candidate)
        root = spill_roots.find { |dir| candidate.start_with?("#{dir}/") }
        return false unless root

        # Again through realpath, so a symlink planted inside the tree cannot
        # lead out of it. A path that will not resolve is left to the read
        # below to report, rather than being called a security problem.
        File.realpath(candidate).start_with?("#{File.realpath(root)}/")
      rescue SystemCallError
        true
      end

      def read_spill(path)
        return warn_about("spill file is larger than #{MAX_SPILL_BYTES} bytes; " \
                          "left as a pointer: #{path}") if File.size(path) > MAX_SPILL_BYTES

        File.read(path)
      rescue SystemCallError
        warn_about("spill file could not be read; left as a pointer: #{path}")
      end

      # The directory Claude Code names after the session id, holding
      # subagents/ and tool-results/. Base#bytes_for already counts what is in
      # it; this is the same convention read rather than measured.
      def sidecar_root
        @sidecar_root ||= session.path.delete_suffix(File.extname(session.path))
      end

      def child_session(path)
        stat = File.stat(path)
        Session.new(agent: session.agent, id: File.basename(path, ".jsonl"), path: path,
                    started_at: nil, updated_at: stat.mtime, bytes: stat.size,
                    format: session.format, fidelity: session.fidelity)
      rescue SystemCallError
        nil
      end
    end
  end
end
