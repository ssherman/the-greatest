# frozen_string_literal: true

require "test_helper"

module CsvExports
  class UserListTest < ActiveSupport::TestCase
    test "albums with a completion date" do
      list = user_lists(:regular_user_music_albums_listened)
      items = list.user_list_items.ordered.to_a

      body = UserList.call(list: list, items: items).string

      assert body.start_with?(Writer::BOM)
      rows = CSV.parse(body.delete_prefix(Writer::BOM))
      assert_equal ["Position", "Title", "Artists", "Year", "Completed On"], rows.first
      assert_equal items.size, rows.size - 1
      assert_equal items.first.listable.title, rows[1][1]
      assert_equal "2026-02-01", rows[1][4]
    end

    test "songs omit the completion column" do
      list = user_lists(:regular_user_music_songs_favorites)

      rows = CSV.parse(UserList.call(list: list, items: list.user_list_items.ordered.to_a).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Artists", "Year"], rows.first
    end

    test "books use an Authors column and first_published_year" do
      list = user_lists(:regular_user_books_favorites)
      items = list.user_list_items.ordered.to_a

      rows = CSV.parse(UserList.call(list: list, items: items).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Authors", "Year"], rows.first
      assert_equal items.first.listable.first_published_year.to_s, rows[1][3].to_s
    end

    test "games and movies have no creator column" do
      list = user_lists(:regular_user_games_favorites)

      rows = CSV.parse(UserList.call(list: list, items: list.user_list_items.ordered.to_a).string.delete_prefix(Writer::BOM))

      assert_equal ["Position", "Title", "Year"], rows.first
    end
  end
end
