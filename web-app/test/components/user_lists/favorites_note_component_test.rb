# frozen_string_literal: true

require "test_helper"

class UserLists::FavoritesNoteComponentTest < ViewComponent::TestCase
  test "renders the rankings note with the listable noun for a Favorites list" do
    render_inline(UserLists::FavoritesNoteComponent.new(user_list: user_lists(:regular_user_books_favorites)))

    assert_text "the books near the top count for more"
  end

  test "renders nothing for a list that does not count toward rankings" do
    render_inline(UserLists::FavoritesNoteComponent.new(user_list: user_lists(:regular_user_books_read)))

    assert_empty page.text.strip
  end
end
