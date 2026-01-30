require "test_helper"

module Admin
  class ListItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @regular_user = users(:regular_user)
      @album_list = lists(:music_albums_list)
      @song_list = lists(:music_songs_list)
      @album = music_albums(:dark_side_of_the_moon)
      @song = music_songs(:time)

      @album_list.list_items.destroy_all
      @song_list.list_items.destroy_all

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    test "should get index with list items" do
      ListItem.create!(list: @album_list, listable: @album, position: 1, verified: true)

      get admin_list_list_items_path(@album_list)
      assert_response :success
      assert_match @album.title, response.body
    end

    test "should get index without list items" do
      get admin_list_list_items_path(@album_list)
      assert_response :success
      assert_match "No items in this list yet", response.body
    end

    test "should create list_item successfully" do
      assert_difference "ListItem.count", 1 do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1, verified: true}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "Item added successfully", response.body
      assert_equal 1, ListItem.last.position
      assert_equal true, ListItem.last.verified
    end

    test "should create list_item and return turbo stream with 3 replacements" do
      post admin_list_list_items_path(@album_list),
        params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "list_items_list"
      assert_turbo_stream action: :replace, target: "add_item_to_list_modal"
    end

    test "should validate position must be greater than zero on create" do
      assert_no_difference "ListItem.count" do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 0}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "Position must be greater than 0", response.body
    end

    test "should prevent duplicate item addition" do
      ListItem.create!(list: @album_list, listable: @album, position: 1)

      assert_no_difference "ListItem.count" do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 2}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "already in this list", response.body
    end

    test "should validate media type compatibility on create" do
      assert_no_difference "ListItem.count" do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @song.id, listable_type: "Music::Song", position: 1}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "not compatible with list type", response.body
    end

    test "should update list_item successfully" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1, verified: false)

      patch admin_list_item_path(list_item),
        params: {list_item: {position: 2, verified: true}},
        as: :turbo_stream

      assert_response :success
      assert_match "Item updated successfully", response.body
      assert_equal 2, list_item.reload.position
      assert_equal true, list_item.reload.verified
    end

    test "should update list_item and return turbo stream with 2 replacements" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)

      patch admin_list_item_path(list_item),
        params: {list_item: {position: 2}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "list_items_list"
    end

    test "should validate position must be greater than zero on update" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)

      patch admin_list_item_path(list_item),
        params: {list_item: {position: 0}},
        as: :turbo_stream

      assert_response :unprocessable_entity
      assert_match "Position must be greater than 0", response.body
    end

    test "should destroy list_item successfully" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)

      assert_difference "ListItem.count", -1 do
        delete admin_list_item_path(list_item), as: :turbo_stream
      end

      assert_response :success
      assert_match "Item removed successfully", response.body
    end

    test "should destroy list_item and return turbo stream with 3 replacements" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)

      delete admin_list_item_path(list_item), as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "list_items_list"
      assert_turbo_stream action: :replace, target: "add_item_to_list_modal"
    end

    test "should work for album lists" do
      post admin_list_list_items_path(@album_list),
        params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1}},
        as: :turbo_stream

      assert_response :success
      assert_equal "Music::Album", ListItem.last.listable_type
    end

    test "should work for song lists" do
      post admin_list_list_items_path(@song_list),
        params: {list_item: {listable_id: @song.id, listable_type: "Music::Song", position: 1}},
        as: :turbo_stream

      assert_response :success
      assert_equal "Music::Song", ListItem.last.listable_type
    end

    test "should require admin authorization for create" do
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListItem.count" do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1}},
          as: :turbo_stream
      end

      assert_response :redirect
    end

    test "should require admin authorization for update" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)
      sign_in_as(@regular_user, stub_auth: true)

      patch admin_list_item_path(list_item),
        params: {list_item: {position: 2}},
        as: :turbo_stream

      assert_response :redirect
    end

    test "should require admin authorization for destroy" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListItem.count" do
        delete admin_list_item_path(list_item), as: :turbo_stream
      end

      assert_response :redirect
    end

    test "destroy_all should delete all list items for album list" do
      ListItem.create!(list: @album_list, listable: @album, position: 1)
      ListItem.create!(list: @album_list, listable: music_albums(:abbey_road), position: 2)

      assert_difference "ListItem.count", -2 do
        delete destroy_all_admin_list_list_items_path(@album_list)
      end

      assert_redirected_to admin_albums_list_path(@album_list)
      follow_redirect!
      assert_match "2 items deleted from list", flash[:notice]
    end

    test "destroy_all should delete all list items for song list" do
      ListItem.create!(list: @song_list, listable: @song, position: 1)
      ListItem.create!(list: @song_list, listable: music_songs(:money), position: 2)

      assert_difference "ListItem.count", -2 do
        delete destroy_all_admin_list_list_items_path(@song_list)
      end

      assert_redirected_to admin_songs_list_path(@song_list)
      follow_redirect!
      assert_match "2 items deleted from list", flash[:notice]
    end

    test "destroy_all should handle empty list gracefully" do
      assert_no_difference "ListItem.count" do
        delete destroy_all_admin_list_list_items_path(@album_list)
      end

      assert_redirected_to admin_albums_list_path(@album_list)
      follow_redirect!
      assert_match "0 items deleted from list", flash[:notice]
    end

    test "destroy_all should require admin authorization" do
      ListItem.create!(list: @album_list, listable: @album, position: 1)
      sign_in_as(@regular_user, stub_auth: true)

      assert_no_difference "ListItem.count" do
        delete destroy_all_admin_list_list_items_path(@album_list)
      end

      assert_response :redirect
    end

    # Metadata JSONB parsing tests
    test "should parse metadata JSON string to hash on update" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)
      json_string = '{"title": "Test Album", "artists": ["Test Artist"], "rank": 1}'

      patch admin_list_item_path(list_item),
        params: {list_item: {metadata: json_string}},
        as: :turbo_stream

      assert_response :success
      list_item.reload
      assert list_item.metadata.is_a?(Hash)
      assert_equal "Test Album", list_item.metadata["title"]
      assert_equal ["Test Artist"], list_item.metadata["artists"]
    end

    test "should parse complex nested metadata JSON on update" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1)
      json_string = <<~JSON.strip
        {
          "rank": 79,
          "title": "Jesus Christ Superstar",
          "artists": ["Various Artists"],
          "mb_artist_names": ["Andrew Lloyd Webber"],
          "musicbrainz_match": true
        }
      JSON

      patch admin_list_item_path(list_item),
        params: {list_item: {metadata: json_string}},
        as: :turbo_stream

      assert_response :success
      list_item.reload
      assert list_item.metadata.is_a?(Hash)
      assert_equal 79, list_item.metadata["rank"]
      assert_equal "Jesus Christ Superstar", list_item.metadata["title"]
      assert_equal true, list_item.metadata["musicbrainz_match"]
    end

    test "should reject invalid metadata JSON on update" do
      list_item = ListItem.create!(list: @album_list, listable: @album, position: 1, metadata: {original: "data"})

      patch admin_list_item_path(list_item),
        params: {list_item: {metadata: "not valid json {"}},
        as: :turbo_stream

      assert_response :unprocessable_entity
      list_item.reload
      assert_equal({original: "data"}.stringify_keys, list_item.metadata)
    end

    test "should parse metadata JSON string on create" do
      json_string = '{"title": "New Album", "rank": 5}'

      assert_difference "ListItem.count", 1 do
        post admin_list_list_items_path(@album_list),
          params: {list_item: {listable_id: @album.id, listable_type: "Music::Album", position: 1, metadata: json_string}},
          as: :turbo_stream
      end

      assert_response :success
      list_item = ListItem.last
      assert list_item.metadata.is_a?(Hash)
      assert_equal "New Album", list_item.metadata["title"]
      assert_equal 5, list_item.metadata["rank"]
    end
  end
end
