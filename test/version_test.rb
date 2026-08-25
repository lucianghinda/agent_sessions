# frozen_string_literal: true

require_relative "test_helper"

class VersionTest < Minitest::Test
  def test_has_a_version
    assert_equal "0.3.0", Agent::Sessions::VERSION
  end
end
