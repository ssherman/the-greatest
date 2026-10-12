require "test_helper"

module Services
  module CategoryCleanup
    class SubjectDecisionsTest < ActiveSupport::TestCase
      setup do
        @space = ::Books::Category.create!(name: "Space Exploration", category_type: :subject)
        @missions = ::Books::Category.create!(name: "Spacecraft missions", category_type: :subject)
        @paris_place = ::Books::Category.create!(name: "Paris", category_type: :location)
        [@space, @missions, @paris_place].each { |c| CategoryItem.create!(category: c, item: books_books(:war_and_peace)) }
        @locations = NameIndex.new(run: "r1", category_type: "location")
        @subjects = NameIndex.new(run: "r1", category_type: "subject")
      end

      def build(category, result)
        entry = NameIndex::Entry.new(category: category, name: category.name, links: 1)
        SubjectDecisions.call(entry: entry, result: {key: "1", name: category.name, merge_into: nil, reason: "r"}.merge(result), locations: @locations, subjects: @subjects)
      end

      test "keep, delete and merge map directly" do
        assert_equal :keep, build(@missions, action: "keep").sole[:action]
        assert_equal :delete, build(@missions, action: "delete").sole[:action]
        assert_equal @space.id, build(@missions, action: "merge", merge_into: "space exploration").sole[:target_category_id]
      end

      test "a merge into an unknown subject fails" do
        assert_equal :failed, build(@missions, action: "merge", merge_into: "Rocketry").sole[:status]
      end

      test "a rename onto an existing subject becomes a merge; a fresh name is a rename" do
        assert_equal :merge, build(@missions, action: "rename", name: "Space Exploration").sole[:action]
        assert_equal "Spacecraft Missions", build(@missions, action: "rename", name: "Spacecraft Missions").sole[:new_name]
      end

      test "is_location merges into the location of that name, or retypes" do
        paris = ::Books::Category.create!(name: "Paris", category_type: :subject)
        assert_equal @paris_place.id, build(paris, action: "is_location").sole[:target_category_id]

        lyon = ::Books::Category.create!(name: "Lyon", category_type: :subject)
        assert_equal :retype, build(lyon, action: "is_location").sole[:action]
      end
    end
  end
end
