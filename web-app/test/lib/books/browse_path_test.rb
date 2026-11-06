require "test_helper"

module Books
  class BrowsePathTest < ActiveSupport::TestCase
    test "the bare categories path omits every default" do
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories)
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, type: "genre", sort: "book_count")
    end

    test "a non-default type becomes its own path segment" do
      assert_equal "/categories/settings", Books::BrowsePath.call(axis: :categories, type: "location")
      assert_equal "/categories/subjects", Books::BrowsePath.call(axis: :categories, type: "subject")
    end

    test "a non-default sort becomes a sorted-by segment" do
      assert_equal "/categories/sorted-by/name", Books::BrowsePath.call(axis: :categories, sort: "name")
    end

    test "both axes compose in type, sort, page order" do
      assert_equal "/categories/subjects/sorted-by/name",
        Books::BrowsePath.call(axis: :categories, type: "subject", sort: "name")
    end

    test "a page beyond the first appends a page segment last" do
      assert_equal "/categories/page/3", Books::BrowsePath.call(axis: :categories, page: 3)
      assert_equal "/categories/settings/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :categories, type: "location", sort: "name", page: 2)
    end

    test "page one and below emit no page segment" do
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, page: 1)
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, page: 0)
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, page: nil)
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, page: "")
    end

    # params[:page] can arrive as an Array (?page[]=1), which does not respond to
    # to_i. It does not raise, and normalizes to the bare path.
    test "an array page does not raise and produces the bare path" do
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, page: ["1"])
    end

    # A path segment is unconstrained input from a URL. Normalizing here means an
    # unknown value can never reach a generated path, so it cannot mint a
    # soft-duplicate URL for a crawler to follow.
    test "an unknown type or sort collapses to the default rather than appearing in the path" do
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, type: "nonsense", sort: "nonsense")
      assert_equal "/categories", Books::BrowsePath.call(axis: :categories, type: "theme")
    end

    test "the countries axis has no type segment even when a type is passed" do
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries)
      assert_equal "/countries", Books::BrowsePath.call(axis: :countries, type: "location")
      assert_equal "/countries/sorted-by/name", Books::BrowsePath.call(axis: :countries, sort: "name")
      assert_equal "/countries/sorted-by/name/page/2",
        Books::BrowsePath.call(axis: :countries, sort: "name", page: 2)
    end

    test "a string axis is accepted" do
      assert_equal "/categories", Books::BrowsePath.call(axis: "categories")
    end

    test "from_legacy_genres maps the old grammar onto the new paths" do
      {
        [{}, {}] => "/categories",
        [{filter: "location"}, {}] => "/categories/settings",
        [{filter: "subject", sort: "name", page: "2"}, {}] => "/categories/subjects/sorted-by/name/page/2",
        [{}, {"filter" => "location", "sort" => "name"}] => "/categories/settings/sorted-by/name",
        [{filter: "subject"}, {"filter" => "location"}] => "/categories/subjects",
        [{}, {"filter" => "theme"}] => "/categories",
        [{filter: "location", page: "1"}, {}] => "/categories/settings"
      }.each do |(path_params, query_params), expected|
        assert_equal expected,
          Books::BrowsePath.from_legacy_genres(path_params: path_params, query_params: query_params)
      end
    end

    test "the genres axis is gone" do
      assert_raises(KeyError) { Books::BrowsePath.call(axis: :genres) }
    end

    test "an unknown axis raises rather than emitting a wrong path" do
      assert_raises KeyError do
        Books::BrowsePath.call(axis: :authors)
      end
    end

    test "the audience type has its own segment" do
      assert_equal "/categories/audiences", Books::BrowsePath.call(axis: :categories, type: "audience")
      assert_equal "/categories/audiences/sorted-by/name", Books::BrowsePath.call(axis: :categories, type: "audience", sort: "name")
    end
  end
end
