require "test_helper"

module Music
  module Artists
    class CategoriesControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"

        @category = categories(:music_rock_genre)
        @artist_rc = ranking_configurations(:music_artists_global)

        @pink_floyd = music_artists(:pink_floyd)
        @david_bowie = music_artists(:david_bowie)

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
      end

      test "should get show with default ranking configuration" do
        get "/artists/categories/rock"
        assert_response :success
      end

      test "should get show with specific ranking configuration" do
        get "/rc/#{@artist_rc.id}/artists/categories/rock"
        assert_response :success
      end

      test "should display category information" do
        get "/artists/categories/rock"
        assert_select "h1", text: /#{@category.name} Artists/
        assert_select ".badge", text: @category.category_type.titleize
        assert_response :success
      end

      test "should display back link to main category page" do
        get "/artists/categories/rock"
        assert_select "a", text: /Back to #{@category.name}/
        assert_response :success
      end

      test "should return 404 for non-existent category" do
        get "/artists/categories/non-existent"
        assert_response :not_found
      end

      test "should return 404 for soft-deleted category" do
        deleted_category = categories(:music_deleted_genre)
        get "/artists/categories/#{deleted_category.slug}"
        assert_response :not_found
      end

      test "should return 404 for non-existent ranking configuration" do
        get "/rc/99999/artists/categories/rock"
        assert_response :not_found
      end

      test "should return 404 for wrong ranking configuration type" do
        album_rc = ranking_configurations(:music_albums_global)
        get "/rc/#{album_rc.id}/artists/categories/rock"
        assert_response :not_found
      end

      test "should handle category with no ranked artists gracefully" do
        category_without_items = categories(:music_uk_location)
        get "/artists/categories/#{category_without_items.slug}"
        assert_response :success
      end
    end
  end
end
