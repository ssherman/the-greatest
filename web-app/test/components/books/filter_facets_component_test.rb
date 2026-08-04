require "test_helper"

module Books
  class FilterFacetsComponentTest < ViewComponent::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)
    end

    def facets_for(categories: [], countries: [], year_start: nil, year_end: nil)
      Books::FilterFacetsQuery.call(
        ranking_configuration: @rc,
        categories: categories,
        countries: countries,
        year_start: year_start,
        year_end: year_end
      )
    end

    def render_component(categories: [], countries: [], year_start: nil, year_end: nil, ranking_configuration: nil)
      render_inline(
        Books::FilterFacetsComponent.new(
          facets: facets_for(categories: categories, countries: countries, year_start: year_start, year_end: year_end),
          categories: categories,
          countries: countries,
          year_start: year_start,
          year_end: year_end,
          ranking_configuration: ranking_configuration
        )
      )
    end

    test "posts to the filters endpoint and escapes the frame" do
      render_component

      assert_selector "form[action='/filters'][method='get'][data-turbo-frame='_top']"
    end

    test "renders a checkbox per faceted genre" do
      render_component

      assert_selector "input[type=checkbox][name='category_slugs[]'][value=novels]"
    end

    test "renders a checkbox per faceted country" do
      render_component

      assert_selector "input[type=checkbox][name='country_slugs[]'][value=french]"
    end

    test "a selected genre renders checked so it can be unchecked" do
      render_component(categories: [categories(:books_novels_genre)])

      assert_selector "input[name='category_slugs[]'][value=novels][checked]"
    end

    test "a selected country renders checked so it can be unchecked" do
      render_component(countries: [books_countries(:french)])

      assert_selector "input[name='country_slugs[]'][value=french][checked]"
    end

    test "preserves a selected non-genre category as a hidden field" do
      render_component(categories: [categories(:books_france_location)])

      assert_selector "input[type=hidden][name='category_slugs[]'][value=france]", visible: :all
      assert_no_selector "input[type=checkbox][name='category_slugs[]'][value=france]"
    end

    test "renders the current year bounds" do
      render_component(year_start: "1900", year_end: "2000")

      assert_selector "input[name=year_start][value='1900']"
      assert_selector "input[name=year_end][value='2000']"
    end

    test "carries a non-primary ranking configuration as a hidden field" do
      alternate = ranking_configurations(:books_inherited)

      render_component(ranking_configuration: alternate)

      assert_selector "input[type=hidden][name=ranking_configuration_id][value='#{alternate.id}']", visible: :all
    end

    test "omits the ranking configuration field when there is none" do
      render_component

      assert_no_selector "input[name=ranking_configuration_id]", visible: :all
    end

    test "the clear control points at the unfiltered root" do
      render_component(categories: [categories(:books_novels_genre)])

      assert_selector "a[href='/']"
    end
  end
end
