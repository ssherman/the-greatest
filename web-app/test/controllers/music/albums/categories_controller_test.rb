require "test_helper"

module Music
  module Albums
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"

        @category = categories(:music_rock_genre)
        @album_rc = ranking_configurations(:music_albums_global)

        @dark_side = music_albums(:dark_side_of_the_moon)
        @wish_you_were_here = music_albums(:wish_you_were_here)

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

      test "should get show with default ranking configuration" do
        get "/albums/categories/rock"
        assert_response :success
      end

      test "should get show with specific ranking configuration" do
        get "/rc/#{@album_rc.id}/albums/categories/rock"
        assert_response :success
      end

      test "should display category information" do
        get "/albums/categories/rock"
        assert_select "h1", text: /#{@category.name} Albums/
        assert_select ".badge", text: @category.category_type.titleize
        assert_response :success
      end

      test "should display back link to main category page" do
        get "/albums/categories/rock"
        assert_select "a", text: /Back to #{@category.name}/
        assert_response :success
      end

      test "should return 404 for non-existent category" do
        get "/albums/categories/non-existent"
        assert_response :not_found
      end

      test "should return 404 for soft-deleted category" do
        deleted_category = categories(:music_deleted_genre)
        get "/albums/categories/#{deleted_category.slug}"
        assert_response :not_found
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/albums/categories/rock"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        artist_rc = ranking_configurations(:music_artists_global)
        get "/rc/#{artist_rc.id}/albums/categories/rock"
        assert_response :not_found
      end

      test "should handle category with no ranked albums gracefully" do
        category_without_items = categories(:music_uk_location)
        get "/albums/categories/#{category_without_items.slug}"
        assert_response :success
      end
    end
  end
end
