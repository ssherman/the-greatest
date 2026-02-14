# frozen_string_literal: true

require "test_helper"

class Games::Igdb::QueryTest < ActiveSupport::TestCase
  test "fields builds correct clause" do
    query = Games::Igdb::Query.new.fields(:name, :rating).to_s
    assert_equal "fields name, rating;", query
  end

  test "fields_all builds wildcard clause" do
    query = Games::Igdb::Query.new.fields_all.to_s
    assert_equal "fields *;", query
  end

  test "exclude builds correct clause" do
    query = Games::Igdb::Query.new.fields_all.exclude(:storyline).to_s
    assert_equal "fields *; exclude storyline;", query
  end

  test "where with string condition" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .where("rating > 75")
      .to_s
    assert_equal "fields name; where rating > 75;", query
  end

  test "where with hash equality" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .where(id: 42)
      .to_s
    assert_equal "fields name; where id = 42;", query
  end

  test "where with hash array (IN clause)" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .where(id: [1, 2, 3])
      .to_s
    assert_equal "fields name; where id = (1,2,3);", query
  end

  test "multiple where calls chain with &" do
    query = Games::Igdb::Query.new
      .fields(:name, :rating)
      .where("rating > 85")
      .where(platforms: [48, 49])
      .to_s
    assert_equal "fields name, rating; where rating > 85 & platforms = (48,49);", query
  end

  test "search builds correct clause" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .search("zelda")
      .to_s
    assert_equal 'fields name; search "zelda";', query
  end

  test "sort builds correct clause" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .sort(:rating, :desc)
      .to_s
    assert_equal "fields name; sort rating desc;", query
  end

  test "limit builds correct clause" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .limit(50)
      .to_s
    assert_equal "fields name; limit 50;", query
  end

  test "offset builds correct clause" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .offset(100)
      .to_s
    assert_equal "fields name; offset 100;", query
  end

  test "complex query matches golden example" do
    query = Games::Igdb::Query.new
      .fields(:name, :rating, :first_release_date)
      .where("rating > 85")
      .where(platforms: [48, 49])
      .sort(:rating, :desc)
      .limit(25)
      .to_s

    assert_equal "fields name, rating, first_release_date; where rating > 85 & platforms = (48,49); sort rating desc; limit 25;", query
  end

  test "limit validates range 1..500" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      Games::Igdb::Query.new.limit(0)
    end

    assert_raises(Games::Igdb::Exceptions::QueryError) do
      Games::Igdb::Query.new.limit(501)
    end

    assert_nothing_raised { Games::Igdb::Query.new.limit(1) }
    assert_nothing_raised { Games::Igdb::Query.new.limit(500) }
  end

  test "offset validates non-negative" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      Games::Igdb::Query.new.offset(-1)
    end

    assert_nothing_raised { Games::Igdb::Query.new.offset(0) }
  end

  test "empty query raises QueryError" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      Games::Igdb::Query.new.to_s
    end
  end

  test "query is immutable" do
    q1 = Games::Igdb::Query.new
    q2 = q1.fields(:name)
    q3 = q2.limit(10)

    assert_raises(Games::Igdb::Exceptions::QueryError) { q1.to_s }
    assert_equal "fields name;", q2.to_s
    assert_equal "fields name; limit 10;", q3.to_s
  end

  test "where with nil value" do
    query = Games::Igdb::Query.new
      .fields(:name)
      .where(parent_game: nil)
      .to_s
    assert_equal "fields name; where parent_game = null;", query
  end

  test "where rejects invalid type" do
    assert_raises(Games::Igdb::Exceptions::QueryError) do
      Games::Igdb::Query.new.where(123)
    end
  end
end
