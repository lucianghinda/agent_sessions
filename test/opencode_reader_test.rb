# frozen_string_literal: true

require_relative "test_helper"
require "sqlite3"

# Shapes taken from the real opencode.db on the machine this was written on
# (2026-08-24): 365 sessions, part types reasoning 4,368 / tool 5,426 /
# step-finish 4,380 / step-start 4,391 / text 839 / patch 569 / file 25.
# Every assistant message row carries its own tokens and cost, and their sum
# equals the store's per-session rollup columns exactly.
class OpencodeReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_turns_with_their_parts
    with_reader(messages: [user_row("m1", parts: [text_part("hello")]),
                           assistant_row("m2", parts: [text_part("hi there")])]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  # One `tool` part row holds both the call and its result; it must become two
  # Parts — the assistant's act and the tool answering — not one or none.
  def test_a_tool_part_becomes_a_tool_use_and_a_tool_result
    tool = { type: "tool", callID: "call_1", tool: "bash",
             state: { status: "completed", input: { command: "ls" }, output: "README.md" } }
    with_reader(messages: [assistant_row("m1", parts: [tool])]) do |reader|
      tool_use, tool_result = reader.messages.first.parts
      assert_equal :tool_use, tool_use.type
      assert_equal "bash", tool_use.name
      assert_equal "call_1", tool_use.call_id
      assert_equal '{"command":"ls"}', tool_use.text
      assert_equal :tool_result, tool_result.type
      assert_equal "call_1", tool_result.call_id
      assert_equal "README.md", tool_result.text
    end
  end

  def test_a_pending_tool_call_has_no_result_part
    tool = { type: "tool", callID: "call_1", tool: "bash",
             state: { status: "running", input: { command: "sleep 60" } } }
    with_reader(messages: [assistant_row("m1", parts: [tool])]) do |reader|
      assert_equal [:tool_use], reader.messages.first.parts.map(&:type)
    end
  end

  def test_a_subtask_becomes_a_tool_use_named_after_its_agent
    subtask = { type: "subtask", prompt: "review the diff", description: "review",
                agent: "build", model: { providerID: "p", modelID: "m" } }
    with_reader(messages: [assistant_row("m1", parts: [subtask])]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :tool_use, part.type
      assert_equal "build", part.name
      assert_equal "review the diff", part.text
      assert_empty reader.warnings
    end
  end

  def test_reasoning_becomes_a_thinking_part
    with_reader(messages: [assistant_row("m1", parts: [{ type: "reasoning", text: "hmm" }])]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :thinking, part.type
      assert_equal "hmm", part.text
    end
  end

  # step markers, patches, file attachments: state, not conversation. Skipped
  # in silence, but rule 1 keeps them reachable — they stay in raw.
  def test_state_parts_are_neither_parts_nor_warnings_but_stay_in_raw
    parts = [text_part("done"),
             { type: "step-start" },
             { type: "patch", hash: "abc", files: ["/x.rb"] },
             { type: "file", mime: "image/png" }]
    with_reader(messages: [assistant_row("m1", parts: parts)]) do |reader|
      message = reader.messages.first
      assert_equal [:text], message.parts.map(&:type)
      assert_empty reader.warnings
      assert_equal %w[text step-start patch file], message.raw["parts"].map { |p| p["type"] }
    end
  end

  # An assistant row's own tokens are the per-message truth (verified equal to
  # the sum of its step-finish parts on real data), and camelCase-free:
  # cache.read / cache.write nest under tokens.cache.
  def test_an_assistant_message_carries_usage_cost_and_model
    row = assistant_row("m1", parts: [text_part("ok")],
                        tokens: { input: 10_557, output: 221, reasoning: 138,
                                  cache: { read: 489, write: 7 } },
                        cost: 0.0123)
    with_reader(messages: [row]) do |reader|
      message = reader.messages.first
      assert_equal "glm-4.7", message.model
      assert_equal 10_557, message.usage.input
      assert_equal 221, message.usage.output
      assert_equal 138, message.usage.reasoning
      assert_equal 489, message.usage.cache_read
      assert_equal 7, message.usage.cache_creation
      assert_in_delta 0.0123, message.usage.cost
    end
  end

  def test_usage_sums_across_messages
    rows = [assistant_row("m1", parts: [], tokens: { input: 10, output: 5, cache: {} }, cost: 0),
            assistant_row("m2", parts: [], tokens: { input: 7, output: 3, cache: {} }, cost: 0)]
    with_reader(messages: rows) do |reader|
      assert_equal 17, reader.usage.input
      assert_equal 8, reader.usage.output
      assert_equal 0, reader.usage.cost, "a $0 subscription session is a real answer, not absence"
    end
  end

  # The schema generation tokentelemetry observed carried tokens only on
  # step-finish parts. A message row without its own tokens falls back to
  # summing them — and a row WITH tokens never also counts its parts.
  def test_step_finish_tokens_are_the_fallback_never_an_addition
    old_style = message_row("m1", role: "assistant",
                            parts: [text_part("ok"),
                                    step_finish(input: 200, output: 30),
                                    step_finish(input: 100, output: 20)])
    both = assistant_row("m2", parts: [step_finish(input: 999, output: 999)],
                         tokens: { input: 50, output: 5, cache: {} }, cost: 0)
    with_reader(messages: [old_style, both]) do |reader|
      first, second = reader.messages
      assert_equal 300, first.usage.input
      assert_equal 50, second.usage.input, "message tokens win; parts must not add on top"
      assert_equal 350, reader.usage.input
    end
  end

  def test_a_compaction_part_is_a_boundary_with_an_unknown_count
    row = assistant_row("m1", parts: [{ type: "compaction", auto: false }])
    with_reader(messages: [row]) do |reader|
      boundary = reader.compactions.first
      refute_nil boundary
      assert_nil boundary.replaced_count, "opencode records no count; nil must not become zero"
      assert_empty reader.messages.first.parts
    end
  end

  def test_messages_carry_the_row_timestamp
    with_reader(messages: [user_row("m1", parts: [text_part("hi")])]) do |reader|
      assert_equal Time.at(1_769_492_050.574), reader.messages.first.at
    end
  end

  def test_a_message_row_holding_invalid_json_is_skipped_with_a_warning
    with_db do |db_path, env|
      insert_session(db_path)
      db = SQLite3::Database.new(db_path)
      db.execute("INSERT INTO message VALUES (?, ?, ?, ?)", ["m1", SESSION_ID, 1, "not json"])
      db.close
      reader = read_session(env)
      assert_empty reader.messages
      refute_empty reader.warnings
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_reader(messages: [user_row("m1", parts: [text_part("hello")])], **options, &block)
  end

  def conformance_unknown(&block)
    row = message_row("m1", role: "oracle", parts: [{ type: "telepathy" }])
    with_reader(messages: [row], &block)
  end

  # A corrupt database cannot come out of the adapter's enumeration (that
  # raises UnreadableStore), so the broken fixture builds the Session by hand
  # — which is also how a caller holding a stale Session meets this case.
  def conformance_broken
    with_home do |home, _env|
      db_path = write("not a database at all", home, ".local", "share", "opencode", "opencode.db")
      session = AgentSessions::Session.new(
        agent: :opencode, id: SESSION_ID, path: db_path, started_at: nil,
        updated_at: Time.now, bytes: nil, format: :sqlite, fidelity: :full
      )
      yield AgentSessions.read(session)
    end
  end

  SESSION_ID = "ses_fixture01"
  CREATED_MS = 1_769_492_050_574

  def text_part(text) = { type: "text", text: text }

  def step_finish(input:, output:)
    { type: "step-finish", reason: "tool-calls", cost: 0,
      tokens: { input: input, output: output, reasoning: 0, cache: { read: 0, write: 0 } } }
  end

  def message_row(id, role:, parts:, data: {})
    { id: id, role: role, parts: parts,
      data: { role: role, time: { created: CREATED_MS } }.merge(data) }
  end

  def user_row(id, parts:)
    message_row(id, role: "user", parts: parts,
                data: { model: { providerID: "zai-coding-plan", modelID: "glm-4.7" } })
  end

  def assistant_row(id, parts:, tokens: nil, cost: nil)
    data = { modelID: "glm-4.7", providerID: "zai-coding-plan" }
    data[:tokens] = tokens if tokens
    data[:cost] = cost if cost
    message_row(id, role: "assistant", parts: parts, data: data)
  end

  def with_db
    with_home do |home, env|
      db_path = File.join(home, ".local", "share", "opencode", "opencode.db")
      FileUtils.mkdir_p(File.dirname(db_path))
      db = SQLite3::Database.new(db_path)
      db.execute(<<~SQL)
        CREATE TABLE session (
          id TEXT PRIMARY KEY, directory TEXT NOT NULL,
          time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL
        )
      SQL
      db.execute("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
      db.execute("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, time_created INTEGER, data TEXT)")
      db.close
      yield db_path, env
    end
  end

  def insert_session(db_path)
    db = SQLite3::Database.new(db_path)
    db.execute("INSERT INTO session VALUES (?, ?, ?, ?)",
               [SESSION_ID, "/Users/you/app", CREATED_MS, CREATED_MS])
    db.close
  end

  def with_reader(messages:, **options)
    with_db do |db_path, env|
      insert_session(db_path)
      db = SQLite3::Database.new(db_path)
      messages.each_with_index do |row, index|
        db.execute("INSERT INTO message VALUES (?, ?, ?, ?)",
                   [row[:id], SESSION_ID, CREATED_MS + index, JSON.generate(row[:data])])
        row[:parts].each_with_index do |part, part_index|
          db.execute("INSERT INTO part VALUES (?, ?, ?, ?)",
                     ["#{row[:id]}-p#{part_index}", row[:id], CREATED_MS + part_index, JSON.generate(part)])
        end
      end
      db.close
      yield read_session(env, **options)
    end
  end

  def read_session(env, **options)
    AgentSessions.read(AgentSessions.sessions(:opencode, env: env).first, **options)
  end
end
