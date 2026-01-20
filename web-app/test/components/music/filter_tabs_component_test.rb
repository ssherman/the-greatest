# frozen_string_literal: true

require "test_helper"

class Music::FilterTabsComponentTest < ViewComponent::TestCase
  def test_renders_all_tabs_without_filter
    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: nil
    ))

    assert_selector "[role='tablist']"
    assert_selector "[role='tab']", text: "All Time"
    assert_selector "[role='tab']", text: "1960s"
    assert_selector "[role='tab']", text: "1970s"
    assert_selector "[role='tab']", text: "1980s"
    assert_selector "[role='tab']", text: "1990s"
    assert_selector "[role='tab']", text: "2000s"
    assert_selector "[role='tab']", text: "2010s"
    assert_selector "[role='tab']", text: "2020s"
    assert_selector "[role='tab']", text: "Custom"
  end

  def test_all_time_active_when_no_filter
    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: nil
    ))

    assert_selector "a.tab-active", text: "All Time"
    assert_no_selector "a.tab-active", text: "1990s"
  end

  def test_decade_active_when_decade_filter
    year_filter = ::Filters::YearFilter.parse("1990s")

    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: year_filter
    ))

    assert_selector "a.tab-active", text: "1990s"
    assert_no_selector "a.tab-active", text: "All Time"
  end

  def test_custom_active_when_range_filter
    year_filter = ::Filters::YearFilter.parse("1980-2000")

    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: year_filter
    ))

    assert_selector "button.tab-active", text: "Custom"
    assert_no_selector "a.tab-active", text: "All Time"
  end

  def test_custom_active_when_single_year_filter
    year_filter = ::Filters::YearFilter.parse("1994")

    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: year_filter
    ))

    assert_selector "button.tab-active", text: "Custom"
  end

  def test_custom_active_when_since_filter
    year_filter = ::Filters::YearFilter.parse("1980", mode: "since")

    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: year_filter
    ))

    assert_selector "button.tab-active", text: "Custom"
  end

  def test_custom_active_when_through_filter
    year_filter = ::Filters::YearFilter.parse("1980", mode: "through")

    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: year_filter
    ))

    assert_selector "button.tab-active", text: "Custom"
  end

  def test_renders_modal_with_correct_base_path
    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: nil
    ))

    assert_selector "dialog#year_filter_modal_albums"
    assert_selector "[data-year-range-modal-base-path-value='/albums']"
  end

  def test_renders_modal_for_songs
    render_inline(Music::FilterTabsComponent.new(
      item_type: "songs",
      base_path: "/songs",
      year_filter: nil
    ))

    assert_selector "dialog#year_filter_modal_songs"
    assert_selector "[data-year-range-modal-base-path-value='/songs']"
  end

  def test_decade_links_have_correct_paths
    render_inline(Music::FilterTabsComponent.new(
      item_type: "albums",
      base_path: "/albums",
      year_filter: nil
    ))

    assert_selector "a[href='/albums']", text: "All Time"
    assert_selector "a[href='/albums/1990s']", text: "1990s"
    assert_selector "a[href='/albums/2000s']", text: "2000s"
  end
end
