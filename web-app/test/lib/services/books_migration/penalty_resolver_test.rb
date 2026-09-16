require "test_helper"

class Services::BooksMigration::PenaltyResolverTest < ActiveSupport::TestCase
  R = Services::BooksMigration::PenaltyResolver

  def globals
    [
      Global::Penalty.new(name: "Voters: Voter Count", dynamic_type: :number_of_voters),
      Global::Penalty.new(name: "Voters: Unknown Count", dynamic_type: :voter_count_unknown),
      Global::Penalty.new(name: "List: only covers 1 specific genre", dynamic_type: :category_specific),
      Global::Penalty.new(name: "Voters: not critics, authors, or experts", dynamic_type: nil),
      Global::Penalty.new(name: "List: contains over 500 items(Quantity over Quality)", dynamic_type: nil),
      Global::Penalty.new(name: "List: number of years covered", dynamic_type: :num_years_covered),
      Global::Penalty.new(name: "List: is a follow up/honorable mention to a different list", dynamic_type: nil),
      Global::Penalty.new(name: "List: only covers items with a weird criteria", dynamic_type: nil)
    ]
  end

  def resolver
    R.new(
      globals_by_name: globals.index_by(&:name),
      globals_by_dynamic_type: globals.select(&:dynamic_type).index_by(&:dynamic_type)
    )
  end

  def lc(overrides = {})
    {"name" => "x", "dynamic_type" => nil}.merge(overrides)
  end

  test "dynamic type maps to the seeded global by dynamic_type, ignoring the legacy name" do
    strategy, penalty = resolver.call(lc("name" => "Voters: Voter names unknown", "dynamic_type" => 3))
    assert_equal :reuse, strategy
    assert_equal "Voters: Unknown Count", penalty.name
  end

  test "dynamic type 0 maps to number_of_voters global" do
    _, penalty = resolver.call(lc("name" => "Voters: Voter Count", "dynamic_type" => 0))
    assert_equal "Voters: Voter Count", penalty.name
  end

  test "percentage_western (type 1) always creates a Books penalty" do
    strategy, payload = resolver.call(lc("name" => 'List: only covers mostly "Western Canon" books', "dynamic_type" => 1))
    assert_equal :create_books, strategy
    assert_equal 'List: only covers mostly "Western Canon" books', payload[:name]
    assert_equal "percentage_western", payload[:dynamic_type]
  end

  test "static exact name match reuses the global" do
    strategy, penalty = resolver.call(lc("name" => "Voters: not critics, authors, or experts", "dynamic_type" => nil))
    assert_equal :reuse, strategy
    assert_equal "Voters: not critics, authors, or experts", penalty.name
  end

  test "static alias (books to items) reuses the normalized global" do
    strategy, penalty = resolver.call(lc("name" => "List: contains over 500 books(Quantity over Quality)", "dynamic_type" => nil))
    assert_equal :reuse, strategy
    assert_equal "List: contains over 500 items(Quantity over Quality)", penalty.name
  end

  test "unmatched static creates a Books penalty with nil dynamic_type" do
    strategy, payload = resolver.call(lc("name" => "List: Podcast/Etc that covers 1 book a week/month", "dynamic_type" => nil))
    assert_equal :create_books, strategy
    assert_equal "List: Podcast/Etc that covers 1 book a week/month", payload[:name]
    assert_nil payload[:dynamic_type]
  end

  test "raises when a dynamic type has no seeded global" do
    bare = R.new(globals_by_name: {}, globals_by_dynamic_type: {})
    assert_raises(KeyError) { bare.call(lc("dynamic_type" => 0)) }
  end

  test "honorable mention alias reuses the follow-up global" do
    strategy, penalty = resolver.call(lc("name" => "List: honorable mention"))
    assert_equal :reuse, strategy
    assert_equal "List: is a follow up/honorable mention to a different list", penalty.name
  end

  test "weird criteria alias (books, with the parenthetical) reuses the items global" do
    legacy = "List: only covers books with a weird criteria(books to help you survive the digital age, etc)"
    strategy, penalty = resolver.call(lc("name" => legacy))
    assert_equal :reuse, strategy
    assert_equal "List: only covers items with a weird criteria", penalty.name
  end

  test "every year-span static reuses the num_years_covered global" do
    assert_equal 7, R::YEAR_SPAN_BUCKETS.size
    R::YEAR_SPAN_BUCKETS.each do |legacy_name, bucket|
      strategy, penalty = resolver.call(lc("name" => legacy_name))
      assert_equal :reuse, strategy, legacy_name
      assert_equal "num_years_covered", penalty.dynamic_type, legacy_name
      assert_kind_of Integer, bucket
      assert_operator bucket, :>, 0
    end
  end

  test "year-span buckets carry the legacy years" do
    assert_equal 1, R::YEAR_SPAN_BUCKETS["List: only covers 1 year (yearly book awards, best of the year, etc)"]
    assert_equal 5, R::YEAR_SPAN_BUCKETS["List: only covers 5 years"]
    assert_equal 10, R::YEAR_SPAN_BUCKETS["List: only covers 10 years"]
    assert_equal 25, R::YEAR_SPAN_BUCKETS["List: only covers 25 years"]
    assert_equal 50, R::YEAR_SPAN_BUCKETS["List: only covers 50 years"]
    assert_equal 75, R::YEAR_SPAN_BUCKETS["List: only covers 75 years"]
    assert_equal 100, R::YEAR_SPAN_BUCKETS["List: only covers 100 years"]
  end

  test "raises when a year-span static has no num_years_covered global to reuse" do
    bare = R.new(globals_by_name: {}, globals_by_dynamic_type: {})
    assert_raises(KeyError) { bare.call(lc("name" => "List: only covers 10 years")) }
  end
end
