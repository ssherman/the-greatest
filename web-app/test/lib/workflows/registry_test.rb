require "test_helper"

module Workflows
  class RegistryTest < ActiveSupport::TestCase
    include Workflows::TestDefinitionHelpers

    test "registry resolves the test definition and refuses unknown names" do
      assert_equal Workflows::TestDefinition, Workflows::Registry.fetch("test.diamond")
      assert_raises(KeyError) { Workflows::Registry.fetch("nope") }
    end

    test "unregister removes a registered definition" do
      Workflows::Registry.unregister("test.diamond")
      assert_raises(KeyError) { Workflows::Registry.fetch("test.diamond") }
    end

    test "the books workflow names are known to the registry" do
      assert_equal %w[books.author_enrichment books.book_enrichment], Workflows::Registry::DEFINITIONS.keys.sort
    end

    test "definition exposes its steps by key" do
      definition = Workflows::TestDefinition
      assert_equal [:a, :b, :c], definition.steps.map(&:key)
      assert_equal({a: :finish, b: :release}, definition.step(:c).waits_on)
      assert_nil definition.step(:nope)
      assert_equal [Books::Author, 1], [definition.target_class, definition.version]
    end

    test "step build applies the defaults" do
      step = Workflows::Step.build(key: :x, queue: :low, adapter: ->(step:, run:, target:) {})
      assert_equal [{}, 3, 10.minutes, nil, nil], [step.waits_on, step.max_attempts, step.lease, step.skip_if, step.on_terminal]
    end

    test "test definition adapters call the configured outcome" do
      Workflows::TestDefinition.outcomes[:a] = ->(step:, run:, target:) { Workflows::Outcome.succeeded("custom", {"x" => 1}) }
      outcome = Workflows::TestDefinition.step(:a).adapter.call(step: nil, run: nil, target: nil)
      assert_equal ["custom", {"x" => 1}], [outcome.outcome, outcome.result]
    end

    # Pairs with the stub test above: in either order, a test starts with no
    # stubbed outcomes because the helper's teardown clears them.
    test "outcomes start empty" do
      assert_equal({}, Workflows::TestDefinition.outcomes)
    end
  end
end
