# frozen_string_literal: true

require "test_helper"

class Books::BookLengthTest < ActiveSupport::TestCase
  # Legacy calls this "extract_max_pages" but it returns the MIDPOINT of the
  # range. Most legacy values are ranges, so this is the case that matters most.
  test "a hyphenated range resolves to the rounded midpoint, not the max" do
    # (200 + 400) / 2 = 300 -> medium. The max, 400, would be moderate.
    assert_equal :medium, Books::BookLength.call(page_range: "200-400", word_count: nil)
  end

  test "midpoint rounds half up" do
    # (100 + 201) / 2.0 = 150.5 -> 151 -> short
    assert_equal :short, Books::BookLength.call(page_range: "100-201", word_count: nil)
  end

  test "a bare positive number is used as-is" do
    assert_equal :medium, Books::BookLength.call(page_range: "300", word_count: nil)
  end

  test "any letter in the page range rejects it entirely" do
    assert_nil Books::BookLength.call(page_range: "300 pages", word_count: nil)
  end

  test "a letter in the page range does not fall through to word_count" do
    # Legacy's two callbacks are independent; page_range containing letters
    # leaves book_length blank rather than deferring to word_count.
    assert_nil Books::BookLength.call(page_range: "xii-300", word_count: 100_000)
  end

  test "a zero part in the range rejects it" do
    assert_nil Books::BookLength.call(page_range: "0-300", word_count: nil)
  end

  test "a non-numeric-but-letterless range rejects it" do
    assert_nil Books::BookLength.call(page_range: "--", word_count: nil)
  end

  test "a bare zero rejects it" do
    assert_nil Books::BookLength.call(page_range: "0", word_count: nil)
  end

  test "word_count is used when page_range is blank" do
    # 82_500 / 275.0 = 300 -> medium
    assert_equal :medium, Books::BookLength.call(page_range: nil, word_count: 82_500)
  end

  test "word_count is used when page_range is an empty string" do
    assert_equal :medium, Books::BookLength.call(page_range: "", word_count: 82_500)
  end

  test "returns nil when neither source is present" do
    assert_nil Books::BookLength.call(page_range: nil, word_count: nil)
  end

  test "maps every threshold band" do
    {
      100 => :very_short,
      149 => :very_short,
      150 => :short,
      250 => :short,
      251 => :medium,
      350 => :medium,
      351 => :moderate,
      500 => :moderate,
      501 => :long,
      1000 => :long,
      1001 => :very_long
    }.each do |pages, expected|
      assert_equal expected, Books::BookLength.call(page_range: pages.to_s, word_count: nil),
        "#{pages} pages should be #{expected}"
    end
  end
end
