require "test_helper"

module Services
  module CategoryCleanup
    class ApplierTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
      end

      def location(name, links: 1, type: :location)
        record = ::Books::Category.create!(name: name, category_type: type)
        CategoryItem.create!(category: record, item: @book) if links.positive?
        record
      end

      def decide(category, action, decided_by: :rule, **attrs)
        CategoryCleanupDecision.create!({
          category: category, run: "r1", stage: "rules", action: action, decided_by: decided_by,
          category_snapshot: CategoryCleanupDecision.snapshot_of(category)
        }.merge(attrs))
      end

      test "applies renames, merges, retypes, parents and deletes, then reconciles" do
        us = location("United States", links: 0)
        typo = location("Chicgo")
        twin = location("Chicago, Illinois")
        hope = location("Hope")
        junk = location("61)")
        rename = decide(typo, :rename, new_name: "Chicago")
        merge = decide(twin, :merge, target_category: typo)
        retype = decide(hope, :retype, new_category_type: ::Category.category_types["subject"])
        parent = decide(typo, :set_parent, parent_chain: ["United States"])
        delete = decide(junk, :delete)

        result = Applier.call(run: "r1")

        assert_equal "Chicago", typo.reload.name
        assert_equal typo, twin.reload.merged_into
        assert hope.reload.subject?
        assert_equal us.id, typo.parent_id
        assert junk.reload.deleted?
        assert CategoryItem.exists?(category: us, item: @book, source: :inherited)
        assert_equal %w[applied] * 5, [rename, merge, retype, parent, delete].map { |d| d.reload.status }
        assert_equal 1, result.data["merge"]
      end

      test "creates missing chain parents with their own parents and records them as kept" do
        chicago = location("Chicago")
        decide(chicago, :set_parent, parent_chain: ["Illinois", "United States", "North America"])

        result = Applier.call(run: "r1")

        illinois = ::Books::Category.find_by!(name: "Illinois", category_type: :location)
        assert_equal ["United States", "North America"], illinois.ancestors.map(&:name)
        assert_equal illinois, chicago.reload.parent
        assert_equal 3, result.data["created"]
        assert CategoryCleanupDecision.exists?(category: illinois, stage: "apply", action: :keep, status: :applied)
        assert CategoryItem.exists?(category: illinois.parent.parent, item: @book, source: :inherited)
      end

      test "a category changed after propose gets stale decisions" do
        place = location("Chicgo")
        decision = decide(place, :rename, new_name: "Chicago")
        place.update!(name: "Chicago, IL")

        Applier.call(run: "r1")

        assert decision.reload.stale?
        assert_equal "Chicago, IL", place.reload.name
      end

      test "a failing decision is marked failed and the rest still apply" do
        gone = location("Gone Target")
        source = location("Source")
        ok = location("chicago")
        failing = decide(source, :merge, target_category: gone)
        gone.update_columns(deleted: true)
        rename = decide(ok, :rename, new_name: "Chicago")

        Applier.call(run: "r1")

        assert failing.reload.failed?
        assert_match "gone", failing.error
        assert rename.reload.applied?
      end

      test "re-running is a no-op, including after a crash between phases" do
        typo = location("Chicgo")
        us = location("United States")
        rename = decide(typo, :rename, new_name: "Chicago")
        decide(typo, :set_parent, parent_chain: ["United States"])
        # Simulate a crash after the rename phase: the rename landed, the set_parent didn't.
        typo.update!(name: "Chicago")
        rename.update!(status: :applied)

        Applier.call(run: "r1")
        assert_equal us, typo.reload.parent

        assert_no_difference -> { CategoryCleanupDecision.applied.count } do
          result = Applier.call(run: "r1")
          assert_equal 0, result.data.values.sum
        end
      end

      test "only_rules applies rule decisions and leaves ai ones proposed" do
        rule_place = location("paris")
        ai_place = location("Lyons")
        decide(rule_place, :rename, new_name: "Paris")
        ai = decide(ai_place, :rename, new_name: "Lyon", decided_by: :ai)

        Applier.call(run: "r1", only_rules: true)

        assert_equal "Paris", rule_place.reload.name
        assert ai.reload.proposed?
      end

      test "never touches a protected category" do
        fiction = categories(:books_fiction_genre)
        ::Books::Category.stubs(:protected_ids).returns([fiction.id])
        decision = decide(fiction, :rename, new_name: "Fiction Books")

        Applier.call(run: "r1")

        assert decision.reload.failed?
        assert_equal "Fiction", fiction.reload.name
      end

      test "leaves music categories alone" do
        rock = categories(:music_rock_genre)
        before = [rock.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
        decide(location("paris"), :rename, new_name: "Paris")

        Applier.call(run: "r1")

        assert_equal before, [rock.reload.attributes, CategoryItem.where(category: rock).pluck(:id, :source)]
      end

      test "refuses to delete a place that has places under it" do
        parent = location("Somewhere")
        ::Books::Category.create!(name: "Inside", category_type: :location, parent: parent)
        decision = decide(parent, :delete)

        Applier.call(run: "r1")

        assert decision.reload.failed?
        refute parent.reload.deleted?
      end

      test "a rules delete and an ai merge for one category: one applies, the other fails cleanly" do
        target = location("Chicago")
        place = location("Chicgo")
        other = location("paris")
        delete = decide(place, :delete)
        merge = decide(place, :merge, target_category: target, decided_by: :ai, stage: "locations_head")
        rename = decide(other, :rename, new_name: "Paris")

        result = nil
        assert_nothing_raised { result = Applier.call(run: "r1") }

        assert merge.reload.applied?
        assert delete.reload.failed?
        assert_match "gone", delete.error
        assert rename.reload.applied?
        assert_equal 1, result.data["failed"]
      end

      test "a rules delete and an ai rename for one category complete the run" do
        place = location("Chicgo")
        delete = decide(place, :delete)
        rename = decide(place, :rename, new_name: "Chicago", decided_by: :ai, stage: "locations_head")

        assert_nothing_raised { Applier.call(run: "r1") }

        assert_equal %w[applied], [rename.reload.status]
        assert_includes %w[applied failed], delete.reload.status
        assert place.reload.deleted?
      end

      test "two renames of one category: the later applied rename is the expected name on a re-run" do
        place = location("Chicgo")
        first = decide(place, :rename, new_name: "Chicago")
        second = decide(place, :rename, new_name: "Chicago, IL", decided_by: :ai, stage: "locations_head")
        place.update!(name: "Chicago, IL")
        first.update!(status: :applied)
        second.update!(status: :applied)
        again = decide(place, :set_parent, parent_chain: ["Nowhere"])
        again.update!(category_snapshot: again.category_snapshot.merge("name" => "Chicgo"))

        Applier.call(run: "r1")

        refute again.reload.stale?
      end
    end
  end
end
