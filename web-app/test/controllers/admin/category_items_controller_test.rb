require "test_helper"

module Admin
  class CategoryItemsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin_user = users(:admin_user)
      @artist = music_artists(:pink_floyd)
      @album = music_albums(:dark_side_of_the_moon)
      @rock_category = categories(:music_rock_genre)
      @progressive_category = categories(:music_progressive_rock_genre)
      @uk_location_category = categories(:music_uk_location)

      host! Rails.application.config.domains[:music]
      sign_in_as(@admin_user, stub_auth: true)
    end

    # Index tests for Artist
    test "should get index for artist with categories" do
      CategoryItem.create!(category: @rock_category, item: @artist)

      get admin_artist_category_items_path(@artist)
      assert_response :success
      assert_match @rock_category.name, response.body
    end

    test "should get index for artist without categories" do
      @artist.category_items.destroy_all

      get admin_artist_category_items_path(@artist)
      assert_response :success
      assert_match "No categories assigned", response.body
    end

    # Index tests for Album
    test "should get index for album with categories" do
      get admin_album_category_items_path(@album)
      assert_response :success
      assert_match @rock_category.name, response.body
    end

    test "should get index for album without categories" do
      @album.category_items.destroy_all

      get admin_album_category_items_path(@album)
      assert_response :success
      assert_match "No categories assigned", response.body
    end

    # Create tests for Artist
    test "should create category_item for artist successfully" do
      @artist.category_items.destroy_all

      assert_difference "CategoryItem.count", 1 do
        post admin_artist_category_items_path(@artist),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "Category added successfully", response.body
    end

    test "should create category_item for artist and return turbo stream" do
      @artist.category_items.destroy_all

      post admin_artist_category_items_path(@artist),
        params: {category_item: {category_id: @rock_category.id}},
        as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "category_items_list"
      assert_turbo_stream action: :replace, target: "add_category_modal"
    end

    # Create tests for Album
    test "should create category_item for album successfully" do
      @album.category_items.destroy_all

      assert_difference "CategoryItem.count", 1 do
        post admin_album_category_items_path(@album),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end

      assert_response :success
      assert_match "Category added successfully", response.body
    end

    # Duplicate prevention
    test "should prevent duplicate category assignment for artist" do
      CategoryItem.find_or_create_by!(category: @rock_category, item: @artist)

      assert_no_difference "CategoryItem.count" do
        post admin_artist_category_items_path(@artist),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "already been taken", response.body
    end

    test "should prevent duplicate category assignment for album" do
      # Album already has rock category from fixtures
      assert_no_difference "CategoryItem.count" do
        post admin_album_category_items_path(@album),
          params: {category_item: {category_id: @rock_category.id}},
          as: :turbo_stream
      end

      assert_response :unprocessable_entity
      assert_match "already been taken", response.body
    end

    # Destroy tests
    test "should destroy category_item for artist successfully" do
      category_item = CategoryItem.create!(category: @rock_category, item: @artist)

      assert_difference "CategoryItem.count", -1 do
        delete admin_category_item_path(category_item), as: :turbo_stream
      end

      assert_response :success
      assert_match "Category removed successfully", response.body
    end

    test "should destroy category_item and return turbo stream" do
      category_item = CategoryItem.create!(category: @rock_category, item: @artist)

      delete admin_category_item_path(category_item), as: :turbo_stream

      assert_response :success
      assert_turbo_stream action: :replace, target: "flash"
      assert_turbo_stream action: :replace, target: "category_items_list"
    end

    test "should destroy category_item for album successfully" do
      # Use existing fixture category_item
      category_item = category_items(:dark_side_rock_category)

      assert_difference "CategoryItem.count", -1 do
        delete admin_category_item_path(category_item), as: :turbo_stream
      end

      assert_response :success
      assert_match "Category removed successfully", response.body
    end

    # Counter cache tests
    test "should update category counter cache when adding category to artist" do
      @artist.category_items.destroy_all
      initial_count = @rock_category.reload.item_count

      post admin_artist_category_items_path(@artist),
        params: {category_item: {category_id: @rock_category.id}},
        as: :turbo_stream

      assert_equal initial_count + 1, @rock_category.reload.item_count
    end

    test "should update category counter cache when removing category from artist" do
      category_item = CategoryItem.create!(category: @rock_category, item: @artist)
      initial_count = @rock_category.reload.item_count

      delete admin_category_item_path(category_item), as: :turbo_stream

      assert_equal initial_count - 1, @rock_category.reload.item_count
    end
  end
end
