require "test_helper"

module Books
  class BrowsePathTest < ActiveSupport::TestCase
    test "the bare genres path omits every default" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "genre", sort: "book_count")
    end

    test "a non-default type becomes a filtered-by segment" do
      assert_equal "/genres/filtered-by/location", Books::BrowsePath.call(axis: :genres, type: "location")
      assert_equal "/genres/filtered-by/subject", Books::BrowsePath.call(axis: :genres, type: "subject")
    end

    test "a non-default sort becomes a sorted-by segment" do
      assert_equal "/genres/sorted-by/name", Books::BrowsePath.call(axis: :genres, sort: "name")
    end

    test "both axes compose in the legacy order" do
      assert_equal "/genres/filtered-by/subject/sorted-by/name",
        Books::BrowsePath.call(axis: :genres, type: "subject", sort: "name")
    end

    test "a page beyond the first appends a page segment last" do
      assert_equal "/genres/page/3", Books::BrowsePath.call(axis: :genres, page: 3)
      assert_equal "/genres/filtered-by/location/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :genres, type: "location", sort: "name", page: 2)
    end

    test "page one and below emit no page segment" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: 1)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: 0)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: nil)
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: "")
    end

    # params[:page] can arrive as an Array (?page[]=1), which does not respond to
    # to_i. It does not raise, and normalizes to the bare path.
    test "an array page does not raise and produces the bare path" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, page: ["1"])
    end

    # A path segment is unconstrained input from a URL. Normalizing here means an
    # unknown value can never reach a generated path, so it cannot mint a
    # soft-duplicate URL for a crawler to follow.
    test "an unknown type or sort collapses to the default rather than appearing in the path" do
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "nonsense", sort: "nonsense")
      assert_equal "/genres", Books::BrowsePath.call(axis: :genres, type: "theme")
    end

    test "the countries axis has no type segment even when a type is passed" do
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries)
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries, type: "location")
      assert_equal "/countries/sorted-by/name", Books::BrowsePath.call(axis: :countries, sort: "name")
      assert_equal "/countries/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :countries, sort: "name", page: 2)
    end

    test "a string axis is accepted" do
      assert_equal "/genres", Books::BrowsePath.call(axis: "genres")
    end

    test "an unknown axis raises rather than emitting a wrong path" do
      assert_raises KeyError do
        Books::BrowsePath.call(axis: :authors)
      end
    end
  end
end
