# frozen_string_literal: true

require_relative "test_helper"

class ZeitwerkTest < Minitest::Test
  def test_agent_sessions_shim_eager_loads_agent_sessions_namespace
    begin
      require "zeitwerk"
    rescue LoadError => e
      flunk "expected zeitwerk dependency for Agent::Sessions loader: #{e.message}"
    end

    Zeitwerk::Loader.eager_load_all

    assert defined?(Agent::Sessions), "require \"agent_sessions\" should define Agent::Sessions"
  end
end
