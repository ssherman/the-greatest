# frozen_string_literal: true

require "test_helper"

class Books::ProvisionalNoticeComponentTest < ViewComponent::TestCase
  test "renders for a provisional record" do
    book = books_books(:war_and_peace)
    book.provisional = true

    render_inline(Books::ProvisionalNoticeComponent.new(record: book))

    assert_selector "[data-testid='provisional-notice']"
  end

  test "renders nothing for a catalog record" do
    render_inline(Books::ProvisionalNoticeComponent.new(record: books_authors(:tolstoy)))

    assert_no_selector "[data-testid='provisional-notice']"
  end
end
