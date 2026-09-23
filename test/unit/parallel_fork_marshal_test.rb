# frozen_string_literal: true

require "test_helper"
require "monitor"

#
#  A parallel worker sends its results to the parent process with Marshal, so a result that holds
#  an object which cannot be marshalled loses every failure that the worker found.
#
describe ParallelForkMarshalSafely do
  let(:error) do
    error = ActiveRecord::StatementInvalid.new("boom")
    error.set_backtrace([ "somewhere.rb:1:in 'block'" ])

    # A connection pool holds a Monitor, and a Monitor cannot be marshalled. An ActiveRecord error
    # holds the pool that it came from, which is how a real failure reaches this state.
    error.instance_variable_set(:@connection_pool, Monitor.new)
    error
  end

  let(:result) do
    result = Minitest::Result.new("test_something")
    result.failures = [ Minitest::UnexpectedError.new(error) ]
    result
  end

  test "a result that cannot be marshalled is not sent as it is" do
    assert_raises(TypeError) { Marshal.dump(result) }
  end

  test "the result is made safe to send" do
    safe = ParallelForkMarshalSafely.marshalable(result)

    assert_nothing_raised { Marshal.dump(safe) }
  end

  test "the class, the message and the backtrace of the error are kept" do
    safe = ParallelForkMarshalSafely.marshalable(result)
    sent = Marshal.load(Marshal.dump(safe))

    assert_equal(1, sent.failures.size)
    assert_match("ActiveRecord::StatementInvalid", sent.failures.first.error.message)
    assert_match("boom", sent.failures.first.error.message)
    assert_equal([ "somewhere.rb:1:in 'block'" ], sent.failures.first.error.backtrace)
  end

  test "a result that can be marshalled is left alone" do
    result = Minitest::Result.new("test_something")
    result.failures = [ Minitest::Assertion.new("plain failure") ]

    assert_same(result, ParallelForkMarshalSafely.marshalable(result))
  end
end
