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

  # One turn. `role` is normalized to :user, :assistant, :system or :tool, with
  # :unknown for a role the adapter did not recognize — the four the spec names
  # were written before any real corpus was read, and Codex promptly said
  # "developer".
  #
  # raw is never dropped (Layer 3 rule 1): when this normalization is wrong or
  # incomplete, a caller escapes the abstraction instead of forking the gem.
  Message = Data.define(:role, :at, :parts, :raw) do
    # self::, for the reason Part::TYPES gives above.
    self::ROLES = %i[user assistant system tool unknown].freeze

    def initialize(role:, at:, parts:, raw:)
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

  # A point where the agent replaced earlier turns with a summary. Not a
  # message: its own payload restates turns already yielded, so anyone counting
  # would count them twice. replaced_count is how many turns it stood in for.
  Compaction = Data.define(:at, :replaced_count, :raw)
end
