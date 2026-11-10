require "test_helper"

module Services
  module Books
    module Categories
      class CandidatesTest < ActiveSupport::TestCase
        def location(name, parent: nil, deleted: false)
          ::Books::Category.create!(name: name, category_type: "location", parent: parent, deleted: deleted)
        end

        test "ranks the exact name ahead of a longer similar one" do
          suburbs = location("Parisian")
          paris = location("Paris")
          result = Candidates.call(name: "Paris", category_type: "location")
          assert_equal [paris.id, suburbs.id], result.map(&:id).first(2)
        end

        test "a subject query never returns locations" do
          location("Parisian Zebra")
          subject = ::Books::Category.create!(name: "Parisian Zebra Studies", category_type: "subject")
          result = Candidates.call(name: "Parisian Zebra", category_type: "subject")
          assert_equal [subject.id], result.map(&:id)
        end

        test "leaves out deleted categories" do
          location("Paris Quux", deleted: true)
          live = location("Paris Quux Region")
          assert_equal [live.id], Candidates.call(name: "Paris Quux", category_type: "location").map(&:id)
        end

        test "fictional true restricts to the Fictional Location subtree and false excludes it" do
          root = location("Fictional Location")
          child = location("Middle-earth Realm", parent: root)
          grandchild = location("Middle-earth Realm Shire", parent: child)
          real = location("Middle-earth Realm Real")
          fict = Candidates.call(name: "Middle-earth Realm", category_type: "location", fictional: true).map(&:id)
          assert_equal [child.id, grandchild.id].sort, fict.sort
          real_ids = Candidates.call(name: "Middle-earth Realm", category_type: "location", fictional: false).map(&:id)
          assert_equal [real.id], real_ids
        end

        test "respects limit" do
          3.times { |i| location("Limitville #{i}") }
          assert_equal 2, Candidates.call(name: "Limitville", category_type: "location", limit: 2).size
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
