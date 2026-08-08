# frozen_string_literal: true

require "test_helper"

module Books
  class SavedSearchTest < ActiveSupport::TestCase
    test "is a SavedSearch subclass stored in the shared table" do
      assert Books::SavedSearch < ::SavedSearch
      assert_equal "saved_searches", Books::SavedSearch.table_name
    end

    test "declares its ranking configuration class" do
      assert_equal ::Books::RankingConfiguration, Books::SavedSearch.ranking_configuration_class
    end

    test "declares the list_type hide_read excludes" do
      assert_equal :read, Books::SavedSearch.excluded_list_type
    end

    test "names its criteria and query classes without resolving them" do
      assert_equal "Books::SavedSearchCriteria", Books::SavedSearch.criteria_class_name
      assert_equal "Books::SavedSearchQuery", Books::SavedSearch.query_class_name
    end

    test "summary renders an empty string for blank criteria" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {})

      assert_equal "", search.summary
    end

    test "summary names the book_type category" do
      search = Books::SavedSearch.new(user: users(:regular_user), criteria: {"book_type" => 0})

      assert_includes search.summary, "Fiction"
    end

    test "summary describes a publication year range" do
      search = Books::SavedSearch.new(
        user: users(:regular_user),
        criteria: {"first_year_published_gt" => "1980", "first_year_published_lt" => "1990"}
      )

      assert_includes search.summary, "1980"
      assert_includes search.summary, "1990"
    end

    test "summary describes the ranked criterion in all three states" do
      base = {user: users(:regular_user)}

      assert_includes Books::SavedSearch.new(**base, criteria: {"ranked" => "true"}).summary, "Ranked"
      assert_includes Books::SavedSearch.new(**base, criteria: {"ranked" => "false"}).summary, "Unranked"
      assert_equal "", Books::SavedSearch.new(**base, criteria: {}).summary
    end

    test "summary joins multiple parts" do
      search = Books::SavedSearch.new(
        user: users(:regular_user),
        criteria: {"book_type" => 0, "max_ranked_position" => 100}
      )

      assert_includes search.summary, " · "
    end
  end
end
