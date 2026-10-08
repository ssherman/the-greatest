# frozen_string_literal: true

require "test_helper"

class Services::BooksMigration::RecommendationConfigMigratorTest < ActiveSupport::TestCase
  def run_migrator(rows)
    m = Services::BooksMigration::RecommendationConfigMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  def legacy_row(overrides = {})
    {
      "id" => 7,
      "user_id" => users(:editor_user).id,
      "book_lengths" => [1, 2],
      "exclude_locations" => true,
      "excluded_category_ids" => [55_555],
      "included_category_all" => true,
      "included_category_ids" => [55_555, 99_999],
      "published_year_start" => 1900,
      "published_year_end" => nil,
      "ranked_limit" => 300,
      "created_at" => Time.zone.parse("2025-01-01 00:00:00"),
      "updated_at" => Time.zone.parse("2026-03-01 12:00:00")
    }.merge(overrides)
  end

  setup do
    @category = ::Books::Category.create!(name: "Migrated Genre", category_type: :genre)
    LegacyIdMap.record(model: "Books::Category", legacy_id: 55_555, new_id: @category.id)
  end

  test "creates a Books::RecommendationConfig with translated criteria" do
    result = run_migrator([legacy_row])
    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]

    config = ::Books::RecommendationConfig.find_by!(user: users(:editor_user))
    assert_equal(
      {"book_length" => [1, 2], "excluded_category_ids" => [@category.id], "genre_match_mode" => "all",
       "included_category_ids" => [@category.id], "first_year_published_gt" => 1900, "max_ranked_position" => 300},
      config.criteria
    )
  end

  test "drops unmapped category ids and reports them" do
    result = run_migrator([legacy_row])
    assert_equal [99_999], result[:data][:dropped_category_ids]
  end

  test "is idempotent: a second run updates the same row" do
    run_migrator([legacy_row])
    run_migrator([legacy_row("ranked_limit" => 50)])
    assert_equal 1, ::Books::RecommendationConfig.where(user: users(:editor_user)).count
    assert_equal 50, ::Books::RecommendationConfig.find_by!(user: users(:editor_user)).criteria["max_ranked_position"]
  end

  test "omits absent values rather than storing nulls" do
    run_migrator([legacy_row("book_lengths" => nil, "excluded_category_ids" => nil, "included_category_ids" => [],
      "included_category_all" => false, "published_year_start" => nil, "ranked_limit" => nil)])
    assert_equal({}, ::Books::RecommendationConfig.find_by!(user: users(:editor_user)).criteria)
  end

  test "fails loudly if the book_length enums disagree" do
    ::Books::Book.stubs(:book_lengths).returns({"very_short" => 0, "short" => 9})
    result = run_migrator([legacy_row])
    assert_not result[:success]
    assert_match(/book_length enum/, result[:error])
  end
end
