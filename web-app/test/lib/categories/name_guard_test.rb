require "test_helper"

module Categories
  class NameGuardTest < ActiveSupport::TestCase
    setup do
      @novels = categories(:books_novels_genre)
    end

    test "finds a name twin, ignoring case and surrounding space" do
      candidate = ::Books::Category.new(name: "  novels ", category_type: :genre)

      assert_equal @novels, NameGuard.conflict(candidate)
    end

    test "finds an alias twin" do
      @novels.update!(alternative_names: ["Prose Fiction"])
      candidate = ::Books::Category.new(name: "prose fiction", category_type: :genre)

      assert_equal @novels, NameGuard.conflict(candidate)
    end

    test "ignores deleted and merged categories" do
      assert_nil NameGuard.conflict(::Books::Category.new(name: "Retired Genre", category_type: :genre))

      merged = ::Books::Category.create!(name: "Old Novels", category_type: :genre)
      merged.update_columns(deleted: true, merged_into_id: @novels.id)
      assert_nil NameGuard.conflict(::Books::Category.new(name: "Old Novels", category_type: :genre))
    end

    test "ignores a twin of another STI type" do
      assert_nil NameGuard.conflict(::Music::Category.new(name: "Novels", category_type: :genre))
    end

    test "a case-only rename of the same record is not a conflict" do
      @novels.name = "NOVELS"

      assert_nil NameGuard.conflict(@novels)
    end

    test "renaming a record onto another record's name conflicts" do
      fiction = categories(:books_fiction_genre)
      fiction.name = "novels"

      assert_equal @novels, NameGuard.conflict(fiction)
    end

    test "an unchanged persisted record is never blocked by a twin it already had" do
      twin = ::Books::Category.create!(name: "Novels Twin", category_type: :genre)
      twin.update_columns(name: "Novels")

      assert_nil NameGuard.conflict(twin.reload)
    end
  end
end
