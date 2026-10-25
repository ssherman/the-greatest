require "test_helper"

module Workflows
  class DefinitionTest < ActiveSupport::TestCase
    def noop_adapter = ->(step:, run:, target:) {}

    test "add_step refuses a duplicate key" do
      adapter = noop_adapter
      klass = Class.new(Workflows::Definition)
      klass.add_step key: :a, queue: :q, adapter: adapter

      error = assert_raises(ArgumentError) { klass.add_step key: :a, queue: :q, adapter: adapter }
      assert_match(/duplicate step key a/, error.message)
    end

    test "validate! refuses a waits_on key that names no step" do
      adapter = noop_adapter
      klass = Class.new(Workflows::Definition)
      klass.add_step key: :a, queue: :q, adapter: adapter
      klass.add_step key: :b, queue: :q, adapter: adapter, waits_on: {nope: :finish}

      error = assert_raises(ArgumentError) { klass.validate! }
      assert_match(/unknown step nope/, error.message)
    end

    test "validate! accepts a waits_on key declared later" do
      adapter = noop_adapter
      klass = Class.new(Workflows::Definition)
      klass.add_step key: :a, queue: :q, adapter: adapter, waits_on: {b: :finish}
      klass.add_step key: :b, queue: :q, adapter: adapter

      assert_nothing_raised { klass.validate! }
    end

    test "the shipped definitions validate" do
      assert_nothing_raised do
        Workflows::Books::AuthorEnrichment.validate!
        Workflows::Books::BookEnrichment.validate!
      end
    end
  end
end
