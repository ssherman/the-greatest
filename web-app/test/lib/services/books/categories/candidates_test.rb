require "test_helper"

module Services
  module Books
    module Categories
      class CandidatesTest < ActiveSupport::TestCase
        def location(name, parent: nil, deleted: false)
          ::Books::Category.create!(name: name, category_type: "location", parent: parent, deleted: deleted)
        end

        test "ranks the exact name ahead of a longer similar one" do
          suburbs = location("Parisian Suburbs")
          paris = location("Paris")
          result = Candidates.new(category_type: "location").call(name: "Paris")
          assert_equal [paris.id, suburbs.id], result.map(&:id).first(2)
        end

        test "a subject query never returns locations" do
          location("Parisian Zebra")
          subject = ::Books::Category.create!(name: "Parisian Zebra Studies", category_type: "subject")
          result = Candidates.new(category_type: "subject").call(name: "Parisian Zebra")
          assert_equal [subject.id], result.map(&:id)
        end

        test "leaves out deleted categories" do
          location("Paris Quux", deleted: true)
          live = location("Paris Quux Region")
          assert_equal [live.id], Candidates.new(category_type: "location").call(name: "Paris Quux").map(&:id)
        end

        test "fictional true restricts to the Fictional Location subtree and false excludes it" do
          root = location("Fictional Location")
          child = location("Middle-earth Realm", parent: root)
          grandchild = location("Middle-earth Realm Shire", parent: child)
          real = location("Middle-earth Realm Real")
          fict = Candidates.new(category_type: "location").call(name: "Middle-earth Realm", fictional: true).map(&:id)
          assert_equal [child.id, grandchild.id].sort, fict.sort
          real_ids = Candidates.new(category_type: "location").call(name: "Middle-earth Realm", fictional: false).map(&:id)
          assert_equal [real.id], real_ids
        end

        test "equal scores break ties by id" do
          # Higher id inserted first, so row order alone cannot satisfy the assertion.
          ::Books::Category.create!(id: 9_000_002, name: "Tieville", category_type: "location")
          ::Books::Category.create!(id: 9_000_001, name: "Tieville", category_type: "location")
          result = Candidates.new(category_type: "location").call(name: "Tieville")
          assert_equal [9_000_001, 9_000_002], result.map(&:id)
        end

        test "respects limit" do
          3.times { |i| location("Limitville #{i}") }
          assert_equal 2, Candidates.new(category_type: "location").call(name: "Limitville", limit: 2).size
        end

        test "fictional_ids includes grandchildren and the root" do
          root = location("Fictional Location")
          child = location("Fic Child", parent: root)
          grandchild = location("Fic Grandchild", parent: child)
          deleted = location("Fic Gone", parent: root, deleted: true)
          ids = Candidates.fictional_ids
          assert_equal Set[root.id, child.id, grandchild.id], ids
          assert_not_includes ids, deleted.id
        end

        test "fictional_ids is empty without the root" do
          assert_equal Set.new, Candidates.fictional_ids
        end
      end
    end
  end
end
