# frozen_string_literal: true

require_relative "test_helper"

Dir[File.expand_path("*_adapter_test.rb", __dir__)].sort.each { |path| require path }

class AdapterConformanceCoverageTest < Minitest::Test
  def test_every_registered_adapter_has_a_conformance_test
    tested_adapters = AdapterConformance.test_classes.filter_map do |test_class|
      instance = test_class.allocate
      instance.send(:adapter_class) if instance.respond_to?(:adapter_class, true)
    end

    missing = Agent::Sessions.registry.values - tested_adapters
    assert_empty missing, "adapters with no conformance test: #{missing.map(&:agent_name).inspect}"
  end
end
