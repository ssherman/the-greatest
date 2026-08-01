# frozen_string_literal: true

require "test_helper"
require "ostruct"

class Lists::CardComponentTest < ViewComponent::TestCase
  def build_card(list_attrs: {}, weight: 100, item_count: 103, noun: "books")
    list = ::OpenStruct.new({
      name: "The Top 10: The Greatest Books of All Time",
      source: "The Top 10 (Book)",
      description: "J. Peder Zane asked 125 writers to name their ten greatest works of fiction.",
      year_published: 2007,
      yearly_award: false,
      activated_at: 2.years.ago
    }.merge(list_attrs))
    list.define_singleton_method(:yearly_award?) { yearly_award }

    Lists::CardComponent.new(
      ranked_list: ::OpenStruct.new(weight: weight, list: list),
      item_count: item_count,
      path: "/lists/1",
      noun: noun
    )
  end

  test "renders weight, item count and name" do
    render_inline(build_card)

    assert_text "Weight 100%"
    assert_text "103 books"
    assert_text "The Top 10: The Greatest Books of All Time"
  end

  test "uses the supplied noun" do
    render_inline(build_card(item_count: 50, noun: "games"))

    assert_text "50 games"
  end

  test "delimits large item counts" do
    render_inline(build_card(item_count: 6933))

    assert_text "6,933 books"
  end

  test "links the title to the supplied path and nothing else" do
    render_inline(build_card)

    assert_selector "a", count: 1
    assert_selector "a[href='/lists/1']", text: "The Top 10: The Greatest Books of All Time"
  end

  test "joins source and year" do
    render_inline(build_card)

    assert_text "The Top 10 (Book) · 2007"
  end

  test "shows Yearly Award in place of the year" do
    render_inline(build_card(list_attrs: {yearly_award: true}))

    assert_text "The Top 10 (Book) · Yearly Award"
  end

  test "omits the source line when there is no source or year" do
    render_inline(build_card(list_attrs: {source: nil, year_published: nil}))

    assert_no_text "·"
  end

  test "renders the description" do
    render_inline(build_card)

    assert_text "J. Peder Zane asked 125 writers"
  end

  test "omits the description when blank" do
    render_inline(build_card(list_attrs: {description: nil}))

    assert_no_selector ".line-clamp-2"
  end

  test "renders added-ago from activated_at" do
    render_inline(build_card(list_attrs: {activated_at: 3.days.ago}))

    assert_text "added 3 days ago"
  end

  test "omits added-ago when activated_at is nil" do
    render_inline(build_card(list_attrs: {activated_at: nil}))

    assert_no_text "added"
  end

  test "escapes html in the description" do
    render_inline(build_card(list_attrs: {description: "<script>alert(1)</script>"}))

    assert_no_selector "script"
  end
end
