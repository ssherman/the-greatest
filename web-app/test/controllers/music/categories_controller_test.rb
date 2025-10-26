require "test_helper"

module Music
  class CategoriesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev.thegreatestmusic.org"

      @category = categories(:music_rock_genre)
      @artist_rc = ranking_configurations(:music_artists_global)
      @album_rc = ranking_configurations(:music_albums_global)

      @pink_floyd = music_artists(:pink_floyd)
      @david_bowie = music_artists(:david_bowie)

      @dark_side = music_albums(:dark_side_of_the_moon)
      @wish_you_were_here = music_albums(:wish_you_were_here)

      CategoryItem.create!(category: @category, item: @pink_floyd)
      CategoryItem.create!(category: @category, item: @david_bowie)

      RankedItem.create!(
        item: @pink_floyd,
        ranking_configuration: @artist_rc,
        rank: 1,
        score: 100.0
      )

      RankedItem.create!(
        item: @david_bowie,
        ranking_configuration: @artist_rc,
        rank: 2,
        score: 95.0
      )

      RankedItem.create!(
        item: @dark_side,
        ranking_configuration: @album_rc,
        rank: 1,
        score: 100.0
      )

      RankedItem.create!(
        item: @wish_you_were_here,
        ranking_configuration: @album_rc,
        rank: 2,
        score: 98.0
      )
    end

    test "should get show with slug" do
      get "/categories/rock"
      assert_response :success
    end

    test "should display category information" do
      get "/categories/rock"
      assert_select "h1", text: @category.name
      assert_select ".badge", text: @category.category_type.titleize
    end

    test "should display top artists" do
      get "/categories/rock"
      assert_select "h2", text: "Top Artists"
      assert_response :success
    end

    test "should display top albums" do
      get "/categories/rock"
      assert_select "h2", text: "Top Albums"
      assert_response :success
    end

    test "should display see all artists link" do
      get "/categories/rock"
      assert_select "a", text: /See all .* artists/
      assert_response :success
    end

    test "should display see all albums link" do
      get "/categories/rock"
      assert_select "a", text: /See all .* albums/
      assert_response :success
    end

    test "should return 404 for non-existent category" do
      get "/categories/non-existent-category"
      assert_response :not_found
    end

    test "should return 404 for soft-deleted category" do
      deleted_category = categories(:music_deleted_genre)
      get "/categories/#{deleted_category.slug}"
      assert_response :not_found
    end

    test "should handle category with no ranked artists gracefully" do
      category_without_items = categories(:music_uk_location)
      get "/categories/#{category_without_items.slug}"
      assert_response :success
    end

    test "should handle missing artist ranking configuration" do
      Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

      get "/categories/rock"
      assert_response :success
    end

    test "should handle missing album ranking configuration" do
      Music::Albums::RankingConfiguration.stubs(:default_primary).returns(nil)

      get "/categories/rock"
      assert_response :success
    end
  end
end
