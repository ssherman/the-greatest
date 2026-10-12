require "test_helper"

module Services
  module CategoryCleanup
    class RulePassTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
      end

      def category(name, type: :location, links: 1, alternative_names: [])
        record = ::Books::Category.create!(name: name, category_type: type, alternative_names: alternative_names)
        [@book, @other].first(links).each { |book| CategoryItem.create!(category: record, item: book) }
        record
      end

      def decisions_for(record)
        CategoryCleanupDecision.where(run: "r1", category: record)
      end

      test "merges case and punctuation twins into the most-linked spelling" do
        winner = category("Washington D.C.", links: 2)
        loser = category("Washington, D.C.", links: 1)

        RulePass.call(run: "r1")

        merge = decisions_for(loser).sole
        assert merge.action_merge?
        assert_equal winner.id, merge.target_category_id
        assert decisions_for(winner).none?
      end

      test "repairs a truncated bracket into a merge with the clean name" do
        japan = category("Japan", links: 2)
        broken = category("Japan (", links: 1)

        RulePass.call(run: "r1")

        assert_equal japan.id, decisions_for(broken).sole.target_category_id
      end

      test "renames when the repaired name has no twin" do
        broken = category("Podgorica (Montenegro")

        RulePass.call(run: "r1")

        rename = decisions_for(broken).sole
        assert rename.action_rename?
        assert_equal "Podgorica", rename.new_name
      end

      test "deletes letterless fragments and categories with no links" do
        fragment = category("61)")
        empty = category("Nowhere At All", links: 0)

        RulePass.call(run: "r1")

        assert decisions_for(fragment).sole.action_delete?
        assert decisions_for(empty).sole.action_delete?
      end

      test "never deletes an empty category that has places under it" do
        parent = category("North America", links: 0)
        ::Books::Category.create!(name: "Canada", category_type: :location, parent: parent)

        RulePass.call(run: "r1")

        assert decisions_for(parent).none?
      end

      test "title-cases a lowercase subject and rewrites ampersands" do
        lower = category("secrets", type: :subject)
        amp = category("Death & Grief", type: :subject)

        RulePass.call(run: "r1")

        assert_equal "Secrets", decisions_for(lower).sole.new_name
        assert_equal "Death and Grief", decisions_for(amp).sole.new_name
      end

      test "merges into a category whose alternative names include the name" do
        kolkata = category("Kolkata", links: 2, alternative_names: ["Calcutta"])
        calcutta = category("Calcutta")

        RulePass.call(run: "r1")

        assert_equal kolkata.id, decisions_for(calcutta).sole.target_category_id
      end

      test "twins in different types are not merged" do
        place = category("Hope", type: :location)
        theme = category("hope", type: :subject)

        RulePass.call(run: "r1")

        assert decisions_for(place).none?
        assert decisions_for(theme).sole.action_rename?
      end

      test "leaves genres and music categories alone" do
        genre = category("fiction stuff", type: :genre)

        RulePass.call(run: "r1")

        assert decisions_for(genre).none?
        assert CategoryCleanupDecision.where(category: categories(:music_uk_location)).none?
      end

      test "rerunning replaces its own proposed decisions and keeps rejected ones" do
        loser = category("Washington, D.C.", links: 1)
        category("Washington D.C.", links: 2)
        RulePass.call(run: "r1")
        decisions_for(loser).update_all(status: CategoryCleanupDecision.statuses["rejected"])

        RulePass.call(run: "r1")

        assert_equal ["rejected"], decisions_for(loser).pluck(:status)
      end

      test "with only_ids it writes decisions for those categories only and prefers existing winners" do
        existing = category("Georgia", links: 1)
        incoming = category("georgia", links: 2)

        RulePass.call(run: "r1", only_ids: [incoming.id], stage: "sync")

        assert_equal existing.id, decisions_for(incoming).sole.target_category_id
        assert decisions_for(existing).none?
      end

      test "categories whose names have no alphanumerics are never twinned or alias-matched" do
        first = category("!!", links: 2)
        second = category("??", links: 1)
        category("Holder", links: 1, alternative_names: ["--"])

        RulePass.call(run: "r1")

        assert decisions_for(first).none?
        assert decisions_for(second).none?
      end

      test "each decision snapshots its category" do
        broken = category("Podgorica (Montenegro")

        RulePass.call(run: "r1")

        assert_equal "Podgorica (Montenegro", decisions_for(broken).sole.category_snapshot["name"]
      end
    end
  end
end
