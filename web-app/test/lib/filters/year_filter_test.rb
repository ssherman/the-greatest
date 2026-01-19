require "test_helper"

class ::Filters::YearFilterTest < ActiveSupport::TestCase
  test "parses decade format" do
    result = ::Filters::YearFilter.parse("1990s")

    assert_equal 1990, result.start_year
    assert_equal 1999, result.end_year
    assert_equal "1990s", result.display
    assert_equal :decade, result.type
  end

  test "parses range format" do
    result = ::Filters::YearFilter.parse("1980-2000")

    assert_equal 1980, result.start_year
    assert_equal 2000, result.end_year
    assert_equal "1980-2000", result.display
    assert_equal :range, result.type
  end

  test "parses single year format" do
    result = ::Filters::YearFilter.parse("1994")

    assert_equal 1994, result.start_year
    assert_equal 1994, result.end_year
    assert_equal "1994", result.display
    assert_equal :single, result.type
  end

  test "parses since mode for open-end range" do
    result = ::Filters::YearFilter.parse("1980", mode: "since")

    assert_equal 1980, result.start_year
    assert_nil result.end_year
    assert_equal "1980", result.display
    assert_equal :since, result.type
  end

  test "parses through mode for open-start range" do
    result = ::Filters::YearFilter.parse("1980", mode: "through")

    assert_nil result.start_year
    assert_equal 1980, result.end_year
    assert_equal "1980", result.display
    assert_equal :through, result.type
  end

  test "returns nil for blank input" do
    assert_nil ::Filters::YearFilter.parse(nil)
    assert_nil ::Filters::YearFilter.parse("")
  end

  test "raises ArgumentError for invalid format" do
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("invalid") }
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("19s") }
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("199s") }
  end

  test "raises ArgumentError when range start is greater than end" do
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("2000-1980") }
  end

  test "raises ArgumentError for invalid year in since mode" do
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("invalid", mode: "since") }
  end

  test "raises ArgumentError for invalid year in through mode" do
    assert_raises(ArgumentError) { ::Filters::YearFilter.parse("invalid", mode: "through") }
  end

  test "handles edge case decades" do
    result = ::Filters::YearFilter.parse("2020s")

    assert_equal 2020, result.start_year
    assert_equal 2029, result.end_year
    assert_equal :decade, result.type
  end
end
