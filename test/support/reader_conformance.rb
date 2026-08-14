# frozen_string_literal: true

# Include in a reader test and define three fixture builders, each yielding a
# reader over a store this agent would actually write:
#
#   conformance_hello(**options) { |reader| }   one user turn whose text is "hello"
#   conformance_unknown          { |reader| }   one record this reader cannot classify
#   conformance_broken           { |reader| }   a store file that is not valid for this format
#
# What is asserted here is the contract from design doc §5 — the three rules
# that make Layer 3 survivable — plus the API shape every reader shares. Each
# reader maps its own agent's records, and nothing here checks that mapping;
# that is what the per-agent test files are for. This checks the promises a
# caller relies on without knowing which agent produced the session.
module ReaderConformance
  include FixtureHelpers

  def test_conformance_reads_a_user_turn
    conformance_hello do |reader|
      message = reader.messages.first
      refute_nil message, "expected the fixture's single turn to be read"
      assert_equal :user, message.role
      assert_equal "hello", message.text
    end
  end

  # Rule 1: raw is never dropped, so a caller can escape a normalization that is
  # wrong or incomplete instead of forking the gem.
  def test_conformance_raw_is_the_original_record
    conformance_hello do |reader|
      raw = reader.messages.first.raw
      assert_kind_of Hash, raw
      refute_empty raw, "raw must carry the record, not an empty placeholder"
    end
  end

  def test_conformance_parts_declare_known_types
    conformance_hello do |reader|
      reader.messages.flat_map(&:parts).each do |part|
        assert_includes AgentSessions::Part::TYPES, part.type
      end
    end
  end

  # Rule 3: each_message streams. Without a block it hands back an Enumerator
  # rather than materializing, and with one it agrees with `messages`.
  def test_conformance_each_message_is_an_enumerator_without_a_block
    conformance_hello do |reader|
      assert_kind_of Enumerator, reader.each_message
      assert_equal reader.messages.map(&:text), reader.each_message.map(&:text)
    end
  end

  def test_conformance_a_reader_can_be_read_twice
    conformance_hello do |reader|
      first = reader.messages.map(&:text)
      assert_equal first, reader.messages.map(&:text), "a second pass must not lose or duplicate messages"
    end
  end

  # Rule 2: an unrecognized record becomes an :unknown part and a warning, never
  # an exception. Every agent adds record types without asking anyone.
  def test_conformance_an_unrecognized_record_warns_rather_than_raising
    conformance_unknown do |reader|
      messages = nil
      assert_silent { messages = reader.messages }
      refute_empty reader.warnings, "an unrecognized record must be reported"
      reader.warnings.each { |warning| assert_kind_of String, warning }
      messages.flat_map(&:parts).each { |part| assert_includes AgentSessions::Part::TYPES, part.type }
    end
  end

  # A store file this reader cannot make sense of is a warning and an empty
  # read, never a crash: one corrupt file must not take down a sweep.
  def test_conformance_a_broken_store_file_warns_rather_than_raising
    conformance_broken do |reader|
      assert_empty reader.messages
      refute_empty reader.warnings
    end
  end

  def test_conformance_warnings_do_not_repeat_across_passes
    conformance_unknown do |reader|
      reader.messages
      once = reader.warnings.size
      reader.messages
      assert_equal once, reader.warnings.size, "warnings must be reported once, not once per pass"
    end
  end

  def test_conformance_declares_fidelity_and_partiality
    conformance_hello do |reader|
      assert_includes AgentSessions::Adapters::Base::FIDELITIES, reader.fidelity
      assert_includes [true, false], reader.partial?
    end
  end

  def test_conformance_compactions_are_a_list
    conformance_hello { |reader| assert_kind_of Array, reader.compactions }
  end
end
