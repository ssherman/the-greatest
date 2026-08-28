# frozen_string_literal: true

require "test_helper"

class Books::ReadingGoals::BookCardComponentTest < ViewComponent::TestCase
  test "renders the standard book card content with its completion date" do
    book = books_books(:war_and_peace)
    item = UserListItem.new(listable: book, completed_on: Date.new(2026, 8, 26))

    render_inline Books::ReadingGoals::BookCardComponent.new(item: item, index: 0)

    assert_link "War and Peace", href: "/book/war-and-peace"
    assert_text "Leo Tolstoy"
    assert_selector "[data-listable-type='Books::Book'][data-listable-id='#{book.id}']"
    assert_text "Completed August 26, 2026"
  end
end
