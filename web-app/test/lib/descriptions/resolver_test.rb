require "test_helper"

module Descriptions
  class ResolverTest < ActiveSupport::TestCase
    test "returns the preferred row over a higher-priority normal row" do
      rows = [descriptions(:crime_ai), descriptions(:crime_preferred)]
      assert_equal descriptions(:crime_preferred), Descriptions::Resolver.call(rows)
    end

    test "falls back to source priority among normal rows" do
      rows = [descriptions(:war_and_peace_wikipedia), descriptions(:war_and_peace_ai)]
      assert_equal descriptions(:war_and_peace_ai), Descriptions::Resolver.call(rows)
    end

    test "never selects a deprecated row even when it is the only candidate" do
      assert_nil Descriptions::Resolver.call([descriptions(:lonely_deprecated)])
    end

    test "excludes deprecated rows from an otherwise valid set" do
      rows = [descriptions(:crime_deprecated), descriptions(:crime_ai)]
      assert_equal descriptions(:crime_ai), Descriptions::Resolver.call(rows)
    end

    test "scopes by kind" do
      rows = [descriptions(:war_and_peace_ai), descriptions(:war_and_peace_long)]
      assert_equal descriptions(:war_and_peace_long), Descriptions::Resolver.call(rows, kind: :long)
    end

    test "scopes by locale and does not fall back to another locale" do
      rows = [descriptions(:war_and_peace_ai), descriptions(:war_and_peace_fr)]
      assert_equal descriptions(:war_and_peace_fr), Descriptions::Resolver.call(rows, locale: "fr")
      assert_nil Descriptions::Resolver.call([descriptions(:war_and_peace_ai)], locale: "de")
    end

    test "accepts string or symbol for kind" do
      rows = [descriptions(:war_and_peace_long)]
      assert_equal descriptions(:war_and_peace_long), Descriptions::Resolver.call(rows, kind: "long")
      assert_equal descriptions(:war_and_peace_long), Descriptions::Resolver.call(rows, kind: :long)
    end

    test "returns nil for an empty collection" do
      assert_nil Descriptions::Resolver.call([])
    end

    test "breaks a tie between two preferred rows by source priority" do
      manual = descriptions(:crime_preferred)
      ai = descriptions(:crime_ai)
      ai.rank = :preferred
      assert_equal manual, Descriptions::Resolver.call([ai, manual])
    end

    test "SourcePriority::ORDER covers every source value exactly once" do
      assert_equal Description.sources.keys.sort, Descriptions::SourcePriority::ORDER.sort
    end

    test "SourcePriority::ORDER ranks ai_generated and goodreads ahead of every raw-description-derived source" do
      priority = Descriptions::SourcePriority::ORDER
      %w[wikipedia openlibrary publisher other].each do |sourced|
        assert priority.index("ai_generated") < priority.index(sourced)
        assert priority.index("goodreads") < priority.index(sourced)
      end
    end
  end
end
