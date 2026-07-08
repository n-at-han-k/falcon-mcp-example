# frozen_string_literal: true

module InstrumentationTestHelper
  class Instrumentation
    attr_reader :callback
    attr_reader :data

    def initialize
      @callback = ->(data) { @data = data }
    end
  end

  def instrumentation_helper
    @instrumentation_helper ||= Instrumentation.new
  end

  def assert_instrumentation_data(expected_data)
    data = instrumentation_helper.data.dup || {}
    duration = data.delete(:duration)
    assert_not_nil(duration, "Duration should always be set")
    assert_operator(duration, :>=, 0, "Duration should be positive or zero")
    assert_equal(expected_data, data, "Instrumentation data does not match expected data")
  end
end
