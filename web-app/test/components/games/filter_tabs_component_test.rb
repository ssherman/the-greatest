# frozen_string_literal: true

require "test_helper"

class Games::FilterTabsComponentTest < ViewComponent::TestCase
  test "renders All Time plus one tab per decade" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games", year_filter: nil))

    assert_selector "[role='tablist'] a", count: 6
    assert_selector "a[href='/games']", text: "All Time"
    Games::FilterTabsComponent::DECADES.each do |decade|
      assert_selector "a[href='/games/#{decade}']", text: decade
    end
  end

  test "marks All Time active when there is no year filter" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games", year_filter: nil))

    assert_selector "a.tab-active", text: "All Time"
    assert_selector "a.tab-active", count: 1
  end

  test "marks the matching decade active and All Time inactive" do
    render_inline(Games::FilterTabsComponent.new(
      base_path: "/games", year_filter: ::Filters::YearFilter.parse("1990s")
    ))

    assert_selector "a.tab-active", text: "1990s"
    assert_selector "a.tab-active", count: 1
    assert_no_selector "a.tab-active", text: "All Time"
  end

  test "marks Custom active for a range filter, which matches no decade tab" do
    render_inline(Games::FilterTabsComponent.new(
      base_path: "/games", year_filter: ::Filters::YearFilter.parse("1994-1997")
    ))

    assert_selector "button.tab-active", text: "Custom"
    assert_no_selector "a.tab-active"
  end

  test "passes the base path to the custom range modal controller" do
    render_inline(Games::FilterTabsComponent.new(base_path: "/games/best", year_filter: nil))

    assert_selector "[data-controller='year-range-modal'][data-year-range-modal-base-path-value='/games/best']"
  end
end
