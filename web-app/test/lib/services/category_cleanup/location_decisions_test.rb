require "test_helper"

module Services
  module CategoryCleanup
    class LocationDecisionsTest < ActiveSupport::TestCase
      setup do
        @us = ::Books::Category.create!(name: "United States", category_type: :location)
        @chicago = ::Books::Category.create!(name: "Chicago", category_type: :location)
        @hope_subject = ::Books::Category.create!(name: "Hope", category_type: :subject)
        [@us, @chicago].each { |c| CategoryItem.create!(category: c, item: books_books(:war_and_peace)) }
        CategoryItem.create!(category: @hope_subject, item: books_books(:war_and_peace))
        @locations = NameIndex.new(run: "r1", category_type: "location")
        @subjects = NameIndex.new(run: "r1", category_type: "subject")
      end

      def entry_for(category) = @locations.entries.find { |e| e.id == category.id } || NameIndex::Entry.new(category: category, name: category.name, links: 1)

      def result(overrides = {})
        {key: "1", verdict: "real_place", canonical_name: "Chicago", merge_into: nil, parent_chain: ["Illinois", "United States", "North America"],
         place_kind: "city", retype_to: nil, ambiguous: false, reason: "City."}.merge(overrides)
      end

      def build(category, overrides = {})
        LocationDecisions.call(entry: entry_for(category), result: result(overrides), locations: @locations, subjects: @subjects)
      end

      test "a real place with a chain gets a set_parent decision" do
        decisions = build(@chicago)

        assert_equal [:set_parent], decisions.map { |d| d[:action] }
        assert_equal ["Illinois", "United States", "North America"], decisions.first[:parent_chain]
        assert_equal "city", decisions.first[:place_kind]
      end

      test "a new canonical name adds a rename; a name that clashes with another location becomes a merge" do
        renamed = build(@chicago, canonical_name: "Chicago (Illinois)")
        assert_equal [:rename, :set_parent], renamed.map { |d| d[:action] }

        clash = build(@chicago, canonical_name: "United States")
        assert_equal [{action: :merge, target: @us.id}], clash.map { |d| {action: d[:action], target: d[:target_category_id]} }
      end

      test "merge_into resolves to a known location, or fails" do
        ok = build(@chicago, merge_into: "united states")
        assert_equal @us.id, ok.sole[:target_category_id]

        missing = build(@chicago, merge_into: "Atlantis")
        assert_equal :failed, missing.sole[:status]
        assert_match "Atlantis", missing.sole[:error]
      end

      test "junk is deleted; a root with no chain is kept" do
        assert_equal :delete, build(@chicago, verdict: "junk").sole[:action]
        assert_equal :keep, build(@us, canonical_name: "United States", parent_chain: [], place_kind: "country").sole[:action]
      end

      test "a fictional place with no chain goes under Fictional Location" do
        decisions = build(@chicago, verdict: "fictional_place", canonical_name: "Chicago", parent_chain: [])
        assert_equal ["Fictional Location"], decisions.sole[:parent_chain]
      end

      test "not a place merges into the subject of that name, or is retyped" do
        hope = ::Books::Category.create!(name: "Hope", category_type: :location)
        merged = build(hope, verdict: "not_a_place", canonical_name: "Hope", retype_to: "subject", parent_chain: [])
        assert_equal [:merge, @hope_subject.id], [merged.sole[:action], merged.sole[:target_category_id]]

        media = ::Books::Category.create!(name: "Media", category_type: :location)
        retyped = build(media, verdict: "not_a_place", canonical_name: "Media", retype_to: "subject", parent_chain: [])
        assert_equal :retype, retyped.sole[:action]
        assert_equal ::Category.category_types["subject"], retyped.sole[:new_category_type]

        noise = build(media, verdict: "not_a_place", retype_to: nil, parent_chain: [])
        assert_equal :delete, noise.sole[:action]
      end

      test "a chain that contains the place itself or repeats a name fails" do
        own = build(@chicago, parent_chain: ["Chicago", "United States"])
        assert_equal :failed, own.last[:status]

        repeat = build(@chicago, parent_chain: ["Illinois", "illinois"])
        assert_equal :failed, repeat.last[:status]
      end

      test "a chain containing a name with no letters fails, even when the place itself has none" do
        unusable = build(@chicago, parent_chain: ["Illinois", "???"])
        assert_equal :failed, unusable.last[:status]
        assert_match "unusable", unusable.last[:error]

        two = build(@chicago, parent_chain: ["---", "???"])
        assert_match "unusable", two.last[:error]

        letterless = ::Books::Category.create!(name: "???", category_type: :location)
        own = build(letterless, canonical_name: "???", parent_chain: ["Illinois", "---"])
        assert_match "unusable", own.last[:error]
      end

      test "a name another category is being renamed away from is free" do
        georgia = ::Books::Category.create!(name: "Georgia", category_type: :location)
        CategoryItem.create!(category: georgia, item: books_books(:war_and_peace))
        CategoryCleanupDecision.create!(category: georgia, run: "r1", stage: "locations_head", action: :rename, decided_by: :ai, new_name: "Georgia (U.S. state)")
        @locations = NameIndex.new(run: "r1", category_type: "location")

        decisions = build(@chicago, canonical_name: "Georgia", parent_chain: [])

        assert_equal [:rename], decisions.map { |d| d[:action] }
      end

      test "merge_into the place's own name does not merge it into itself" do
        decisions = build(@chicago, merge_into: "Chicago")

        assert_equal [:set_parent], decisions.map { |d| d[:action] }
        assert_equal :keep, build(@chicago, merge_into: "chicago", parent_chain: []).sole[:action]
      end

      test "a case-only rename stays a rename" do
        lower = ::Books::Category.create!(name: "boston", category_type: :location)
        CategoryItem.create!(category: lower, item: books_books(:war_and_peace))
        @locations = NameIndex.new(run: "r1", category_type: "location")

        assert_equal :rename, build(lower, canonical_name: "Boston", parent_chain: []).sole[:action]
      end

      test "an entry named like the fictional root is treated as the root" do
        root = ::Books::Category.create!(name: "Fictional location", category_type: :location)
        decisions = build(root, verdict: "fictional_place", canonical_name: "Fictional location", parent_chain: [])

        assert_equal [:keep], decisions.map { |d| d[:action] }
      end

      test "every decision carries the reason and the ambiguous flag" do
        decision = build(@chicago, ambiguous: true, reason: "Two Chicagos.").sole
        assert decision[:ambiguous]
        assert_equal "Two Chicagos.", decision[:reason]
      end
    end
  end
end
