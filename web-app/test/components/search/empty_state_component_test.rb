# frozen_string_literal: true

require "test_helper"

class Search::EmptyStateComponentTest < ViewComponent::TestCase
  test "renders message" do
    component = Search::EmptyStateComponent.new(message: "Enter a search term to find video games")
    render_inline(component)

    assert_selector "p", text: "Enter a search term to find video games"
  end

  test "renders message with query" do
    component = Search::EmptyStateComponent.new(message: "No results found for", query: "Zelda")
    render_inline(component)

    assert_selector "p", text: /No results found for/
    assert_selector "p", text: /Zelda/
  end

  test "escapes HTML in query" do
    component = Search::EmptyStateComponent.new(message: "No results found for", query: "<script>alert('xss')</script>")
    render_inline(component)

    assert_no_selector "script"
    assert_selector "p", text: /&lt;script&gt;|<script>/  # escaped in output
  end

  test "renders without query when not provided" do
    component = Search::EmptyStateComponent.new(message: "Enter a search term")
    html = render_inline(component)

    assert_selector "p", text: "Enter a search term"
    refute_includes html.to_html, '""'
  end
end
