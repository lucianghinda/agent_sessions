# frozen_string_literal: true

module AgentSessions
  # One piece of a message. `type` is the normalized vocabulary (design doc §5);
  # everything an agent said that this gem could not classify arrives as
  # :unknown rather than as an exception, and the message's `raw` still holds it.
  #
  # text carries the readable content for :text, :thinking and :tool_result.
  # name and call_id are tool plumbing, nil elsewhere. An :image part has
  # neither — its URL or payload stays in raw, because normalizing an image
  # would mean deciding whether to load it, and reading is stat-cheap by design.
  Part = Data.define(:type, :text, :name, :call_id) do
    # self::, not a bare TYPES =. Constant assignment inside a block is
    # lexically scoped, so the bare form defines AgentSessions::TYPES — a
    # generically named constant in the top namespace, and no Part::TYPES at
    # all for a caller (or a conformance test) to check a part against.
    self::TYPES = %i[text thinking tool_use tool_result image unknown].freeze

    # self.class::TYPES for the same reason: inside a block passed to
    # Data.define, a bare constant resolves against the ENCLOSING lexical
    # scope (AgentSessions), never against the class being defined.
    def initialize(type:, text: nil, name: nil, call_id: nil)
      types = self.class::TYPES
      raise ArgumentError, "part type #{type.inspect} must be one of #{types.join(", ")}" unless types.include?(type)

      super
    end
  end

  # Token counts an agent reported, for one message or one whole session,
  # normalized to five DISJOINT buckets: `input` never includes what was read
  # from or written to cache, and `output` never includes `reasoning`. Agents
  # disagree here — Codex's input_tokens includes its cached_input_tokens,
  # Claude's does not (both verified against real stores on this machine,
  # 2026-08-24) — and a caller summing across agents needs one rule, not one
  # per agent. Readers do the subtraction; this object only holds the result.
  #
  # nil means "this format does not record that dimension", and it is load-
  # bearing: absence must never read as zero, for the same reason
  # AgentSessions.read raises on a format with no reader. `cost` is reported
  # by the agent or absent — never derived from a pricing table, which would
  # go stale in a gem and is a consumer's decision anyway.
  Usage = Data.define(:input, :output, :cache_read, :cache_creation, :reasoning, :cost) do
    def initialize(input: nil, output: nil, cache_read: nil, cache_creation: nil, reasoning: nil, cost: nil)
      super
    end

    # Sums dimension-wise, keeping the nil/zero distinction: nil + nil stays
    # nil ("neither side records this"), nil + n is n — one recorded value is
    # a real value, not a value plus an unknown, because per-message absence
    # under a format that does record the dimension means "none reported for
    # this message", the one place absence and zero do coincide.
    def +(other)
      self.class.new(input: sum(input, other.input), output: sum(output, other.output),
                     cache_read: sum(cache_read, other.cache_read),
                     cache_creation: sum(cache_creation, other.cache_creation),
                     reasoning: sum(reasoning, other.reasoning), cost: sum(cost, other.cost))
    end

    private

    def sum(mine, theirs)
      return theirs if mine.nil?
      return mine if theirs.nil?

      mine + theirs
    end
  end

  # One turn. `role` is normalized to :user, :assistant, :system or :tool, with
  # :unknown for a role the adapter did not recognize — the four the spec names
  # were written before any real corpus was read, and Codex promptly said
  # "developer".
  #
  # raw is never dropped (Layer 3 rule 1): when this normalization is wrong or
  # incomplete, a caller escapes the abstraction instead of forking the gem.
  #
  # usage and model are nil wherever the format does not put them on the
  # message itself — Codex records tokens in separate event records and the
  # model in its session header, so its messages carry neither; the reader's
  # session-level `usage` is where those formats answer. A nil here means
  # "not recorded on this message", never "zero tokens".
  Message = Data.define(:role, :at, :parts, :raw, :usage, :model) do
    # self::, for the reason Part::TYPES gives above.
    self::ROLES = %i[user assistant system tool unknown].freeze

    def initialize(role:, at:, parts:, raw:, usage: nil, model: nil)
      roles = self.class::ROLES
      raise ArgumentError, "role #{role.inspect} must be one of #{roles.join(", ")}" unless roles.include?(role)

      super
    end

    # Concatenated :text parts, as the design doc specifies — no separator
    # inserted, because a separator is a formatting decision this layer has no
    # business making. A caller that needs the boundaries has `parts`.
    def text
      parts.select { |part| part.type == :text }.map(&:text).join
    end
  end

  # One message in a branching conversation, with the messages that follow it.
  # Agents that let a turn be edited and re-run record two children under one
  # parent: 380 such branch points sit across 85 of 151 real Claude transcripts,
  # so a caller reading `messages` in file order is reading two alternative
  # histories interleaved without being told.
  #
  # children is a plain Array and the Node is frozen, so the shape is settled
  # before anyone sees it.
  Node = Data.define(:message, :children)

  # A point where the agent replaced earlier turns with a summary. Not a
  # message: its own payload restates turns already yielded, so anyone counting
  # would count them twice. replaced_count is how many turns it stood in for.
  Compaction = Data.define(:at, :replaced_count, :raw)
end
