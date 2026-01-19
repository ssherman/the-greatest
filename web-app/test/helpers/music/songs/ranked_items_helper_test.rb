require "test_helper"

class Music::Songs::RankedItemsHelperTest < ActionView::TestCase
  test "songs_page_title returns default title when no filter" do
    result = songs_page_title(nil)

    assert_equal "Top 100 Greatest Songs of All Time | The Greatest Music", result
  end

  test "songs_page_title formats decade correctly" do
    year_filter = ::Filters::YearFilter.parse("1990s")

    result = songs_page_title(year_filter)

    assert_equal "Greatest Songs of the 1990s | The Greatest Music", result
  end

  test "songs_page_title formats range correctly" do
    year_filter = ::Filters::YearFilter.parse("1980-2000")

    result = songs_page_title(year_filter)

    assert_equal "Greatest Songs from 1980 to 2000 | The Greatest Music", result
  end

  test "songs_page_title formats single year correctly" do
    year_filter = ::Filters::YearFilter.parse("1994")

    result = songs_page_title(year_filter)

    assert_equal "Greatest Songs of 1994 | The Greatest Music", result
  end

  test "songs_page_heading returns heading for filter" do
    year_filter = ::Filters::YearFilter.parse("1990s")

    result = songs_page_heading(year_filter)

    assert_equal "Greatest Songs of the 1990s", result
  end

  test "songs_page_heading returns default heading when no filter" do
    result = songs_page_heading(nil)

    assert_equal "Top Songs", result
  end

  test "songs_page_description includes year context for filter" do
    year_filter = ::Filters::YearFilter.parse("1990s")

    result = songs_page_description(year_filter)

    assert_includes result, "of the 1990s"
  end

  test "songs_page_title formats since correctly" do
    year_filter = ::Filters::YearFilter.parse("1980", mode: "since")

    result = songs_page_title(year_filter)

    assert_equal "Greatest Songs Since 1980 | The Greatest Music", result
  end

  test "songs_page_title formats through correctly" do
    year_filter = ::Filters::YearFilter.parse("1980", mode: "through")

    result = songs_page_title(year_filter)

    assert_equal "Greatest Songs Through 1980 | The Greatest Music", result
  end

  test "songs_page_description includes since context" do
    year_filter = ::Filters::YearFilter.parse("1980", mode: "since")

    result = songs_page_description(year_filter)

    assert_includes result, "since 1980"
  end

  test "songs_page_description includes through context" do
    year_filter = ::Filters::YearFilter.parse("1980", mode: "through")

    result = songs_page_description(year_filter)

    assert_includes result, "through 1980"
  end
end
