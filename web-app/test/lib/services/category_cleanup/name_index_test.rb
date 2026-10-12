require "test_helper"

module Services
  module CategoryCleanup
    class NameIndexTest < ActiveSupport::TestCase
      def location(name, links:, alternative_names: [])
        record = ::Books::Category.create!(name: name, category_type: :location, alternative_names: alternative_names)
        ::Books::Book.order(:id).limit(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def decide(category, action, **attrs)
        CategoryCleanupDecision.create!({category: category, run: "r1", stage: "rules", action: action, decided_by: :rule}.merge(attrs))
      end

      test "applies proposed renames and merges from the run to names and counts" do
        dc = location("Washington D.C.", links: 2)
        twin = location("Washington, D.C.", links: 1)
        lower = location("paris", links: 1)
        decide(twin, :merge, target_category: dc)
        decide(lower, :rename, new_name: "Paris")

        index = NameIndex.new(run: "r1", category_type: "location")
        by_id = index.entries.index_by(&:id)

        refute by_id.key?(twin.id)
        assert_equal 3, by_id[dc.id].links
        assert_equal "Paris", by_id[lower.id].name
      end

      test "lookup matches effective names, original names and alternative names, case-insensitively" do
        kolkata = location("Kolkata", links: 1, alternative_names: ["Calcutta"])
        index = NameIndex.new(run: "r1", category_type: "location")

        assert_equal kolkata.id, index.lookup("kolkata")
        assert_equal kolkata.id, index.lookup("Calcutta")
        assert_nil index.lookup("Bombay")
      end

      test "a name with no letters or digits is never indexed and never looked up" do
        location("???", links: 1, alternative_names: ["!!!"])
        location("Real Place", links: 1)
        index = NameIndex.new(run: "r1", category_type: "location")

        assert_nil index.lookup("---")
        assert_nil index.lookup("???")
        assert_nil index.lookup("!!!")
      end

      test "effective_only lookup ignores a name its category is being renamed away from" do
        georgia = location("Georgia", links: 1)
        decide(georgia, :rename, new_name: "Georgia (U.S. state)")
        index = NameIndex.new(run: "r1", category_type: "location")

        assert_equal georgia.id, index.lookup("Georgia")
        assert_nil index.lookup("Georgia", effective_only: true)
        assert_equal georgia.id, index.lookup("Georgia (U.S. state)", effective_only: true)
      end

      test "applied decisions are not re-applied and the latest proposed rename wins" do
        applied = location("Applied", links: 1)
        decide(applied, :delete, status: :applied)
        renamed = location("Old", links: 1)
        decide(renamed, :rename, new_name: "First")
        decide(renamed, :rename, new_name: "Second")
        by_id = NameIndex.new(run: "r1", category_type: "location").entries.index_by(&:id)

        assert by_id.key?(applied.id)
        assert_equal "Second", by_id[renamed.id].name
      end

      test "head_names lists the most-linked names at or above the head threshold" do
        Rails.configuration.x.categories_cleanup.stubs(:head_min_links).returns(2)
        location("Big Place", links: 2)
        location("Small Place", links: 1)

        names = NameIndex.new(run: "r1", category_type: "location").head_names

        assert_includes names, "Big Place"
        refute_includes names, "Small Place"
      end

      test "only books categories of the given type take part" do
        refute_includes NameIndex.new(run: "r1", category_type: "location").entries.map(&:id), categories(:music_uk_location).id
      end
    end
  end
end
