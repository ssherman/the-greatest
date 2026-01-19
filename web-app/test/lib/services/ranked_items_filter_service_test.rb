require "test_helper"

class Services::RankedItemsFilterServiceTest < ActiveSupport::TestCase
  test "apply_year_filter returns base query when filter is nil" do
    base_query = Music::Album.all
    service = Services::RankedItemsFilterService.new(base_query, table_name: "music_albums")

    result = service.apply_year_filter(nil)

    assert_equal base_query, result
  end

  test "apply_year_filter adds year range condition for closed range" do
    base_query = Music::Album.all
    service = Services::RankedItemsFilterService.new(base_query, table_name: "music_albums")
    year_filter = ::Filters::YearFilter.parse("1990s")

    result = service.apply_year_filter(year_filter)

    assert_includes result.to_sql, "music_albums"
    assert_includes result.to_sql, "release_year"
    assert_includes result.to_sql, "BETWEEN"
  end

  test "apply_year_filter adds >= condition for since mode" do
    base_query = Music::Album.all
    service = Services::RankedItemsFilterService.new(base_query, table_name: "music_albums")
    year_filter = ::Filters::YearFilter.parse("1980", mode: "since")

    result = service.apply_year_filter(year_filter)

    assert_includes result.to_sql, "release_year"
    assert_includes result.to_sql, ">="
  end

  test "apply_year_filter adds <= condition for through mode" do
    base_query = Music::Album.all
    service = Services::RankedItemsFilterService.new(base_query, table_name: "music_albums")
    year_filter = ::Filters::YearFilter.parse("1980", mode: "through")

    result = service.apply_year_filter(year_filter)

    assert_includes result.to_sql, "release_year"
    assert_includes result.to_sql, "<="
  end
end
