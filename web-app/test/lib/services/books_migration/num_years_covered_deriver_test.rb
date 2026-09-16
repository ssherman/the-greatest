require "test_helper"

class Services::BooksMigration::NumYearsCoveredDeriverTest < ActiveSupport::TestCase
  D = Services::BooksMigration::NumYearsCoveredDeriver

  def row(overrides = {})
    {id: 1, name: "x", description: nil, year_published: 2020, bucket: 25, buckets: [25]}.merge(overrides)
  end

  def derive(overrides = {})
    D.call([row(overrides)], current_year: 2026).first
  end

  test "one-year bucket is never parsed, whatever the name says" do
    e = derive(name: "Pulitzer Prize for Fiction 1918-2026", bucket: 1, buckets: [1])
    assert_equal 1, e.years
    assert_match(/never parsed/, e.reason)
  end

  test "explicit range is end minus start plus one" do
    assert_equal 101, derive(name: "The 100 Greatest American Novels, 1893 – 1993").years
    assert_equal 21, derive(name: "Top 20 South African Books, 1994-2014").years
    assert_equal 26, derive(name: "Top 10 Novels from 1980 to 2005").years
  end

  test "range beats past-N-years when both appear" do
    e = derive(name: "The 101 GREATEST PLAYS of the Past 100 Years (1920-2020)")
    assert_equal 101, e.years
    assert_match(/range 1920-2020/, e.reason)
  end

  test "past, last and previous N years" do
    assert_equal 30, derive(name: "The 30 best fiction books of the last 30 years").years
    assert_equal 20, derive(name: "Most Influential Book of the Past 20 Years").years
    assert_equal 90, derive(name: "Works of the previous 90 years").years
  end

  test "half and quarter century" do
    assert_equal 50, derive(name: "Best of the last half-century").years
    assert_equal 25, derive(name: "100 Best Books of the Quarter Century").years
  end

  test "since a year counts up to the publication year" do
    e = derive(name: "The Two Hundred Best Novels in English Since 1950", year_published: 2011)
    assert_equal 62, e.years
    assert_match(/since 1950/, e.reason)
    assert_empty e.flags
  end

  test "since a year with no publication year uses the current year and flags it" do
    e = derive(name: "The Best Since 1945", year_published: nil)
    assert_equal 82, e.years
    assert_includes e.flags, "NO year_published (used 2026)"
  end

  test "since a year later than publication falls through" do
    e = derive(name: "Since 2025", year_published: 2020, bucket: 10, buckets: [10])
    assert_equal 10, e.years
    assert_equal "unparsed", e.reason
  end

  test "decade patterns yield ten" do
    assert_equal 10, derive(name: "The Best Of The 1980s").years
    assert_equal 10, derive(name: "PEOPLE Picks the Best Books From the 80s").years
    assert_equal 10, derive(name: "The 24 Best Books of the Decade").years
  end

  test "ten per decade is not a decade list" do
    e = derive(name: "Zeit Literaturkanon", description: "70 European novels published between 1945 and 2009, ten titles for each decade.", year_published: 2010, bucket: 75, buckets: [75])
    assert_equal 65, e.years
    assert_match(/range 1945-2009/, e.reason)
  end

  test "every decade and per decade do not match the decade rule either" do
    assert_equal 75, derive(name: "Ten from every decade", bucket: 75, buckets: [75]).years
    assert_equal 75, derive(name: "Ten per decade", bucket: 75, buckets: [75]).years
  end

  test "21st century is publication year minus 2000" do
    assert_equal 24, derive(name: "100 Best Books of the 21st Century", year_published: 2024).years
    assert_equal 15, derive(name: "The 21st Century's 12 Greatest Novels", year_published: 2015).years
    assert_equal 19, derive(name: "21 books for the XXI century", year_published: 2019).years
  end

  test "21st century with no publication year uses the current year and flags it" do
    e = derive(name: "Best of the 21st century", year_published: nil)
    assert_equal 26, e.years
    assert_includes e.flags, "NO year_published (used 2026)"
  end

  test "20th century and century yield one hundred" do
    assert_equal 100, derive(name: "100 Best 20th-Century American Books").years
    assert_equal 100, derive(name: "Waterstone's Books of the Century").years
    assert_equal 100, derive(name: "Kanon na koniec wieku").years
  end

  test "millennium yields no value and is left to the reviewer" do
    e = derive(name: "The Best Fiction of the Millennium", bucket: 10, buckets: [10])
    assert_equal 10, e.years
    assert_match(/millennium/, e.reason)
  end

  test "name beats description" do
    e = derive(name: "Africa's 100 Best Books of the 20th Century",
      description: "Compiled early in the 21st century.", year_published: 2002, bucket: 100, buckets: [100])
    assert_equal 100, e.years
    assert_empty e.flags
  end

  test "description is used only when the name yields nothing, and is flagged" do
    e = derive(name: "The New Vanguard", description: "Novels of the 21st century.", year_published: 2018)
    assert_equal 18, e.years
    assert_includes e.flags, "FROM DESCRIPTION"
  end

  test "unparsed keeps the bucket" do
    e = derive(name: "50 Books That Defined Their Era", bucket: 100, buckets: [100])
    assert_equal 100, e.years
    assert_equal "unparsed", e.reason
  end

  test "conflicting legacy buckets are flagged" do
    e = derive(name: "The 10 Best Books Through Time", bucket: 25, buckets: [1, 25])
    assert_includes e.flags, "CONFLICT 1/25, highest RC wins"
  end

  test "to_line is a YAML entry with the reviewer's context in a comment" do
    e = derive(name: "100 Best Books of the 21st Century", year_published: 2024)
    assert_equal "1: 24   # 100 Best Books of the 21st Century  (25 -> 21st century so far, published 2024)", e.to_line
    assert_equal({1 => 24}, YAML.safe_load(e.to_line))
  end

  test "to_line flattens a newline in the name" do
    e = derive(name: "Line one\nline two", bucket: 25, buckets: [25])
    assert_equal({1 => 25}, YAML.safe_load(e.to_line))
    refute_includes e.to_line, "\n"
  end

  test "a since-year that falls through leaves no year_published flag behind" do
    e = derive(name: "Since 2026", year_published: nil, bucket: 10, buckets: [10])
    assert_equal 10, e.years
    assert_equal "unparsed", e.reason
    assert_empty e.flags
  end

  test "to_line appends flags after the reason" do
    e = derive(name: "The New Vanguard", description: "Novels of the 21st century.", year_published: nil)
    assert_match(/\(25 -> 21st century so far, published 2026; FROM DESCRIPTION; NO year_published \(used 2026\)\)\z/, e.to_line)
  end
end
