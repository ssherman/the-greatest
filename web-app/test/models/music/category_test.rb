require "test_helper"

module Music
  class CategoryTest < ActiveSupport::TestCase
    def setup
      @rock_genre = categories(:music_rock_genre)
      @progressive_rock = categories(:music_progressive_rock_genre)
      @uk_location = categories(:music_uk_location)
    end

    test "should be a Music::Category" do
      assert_instance_of Music::Category, @rock_genre
      assert_equal "Music::Category", @rock_genre.type
    end

    test "should inherit from base Category" do
      assert_kind_of Category, @rock_genre
    end

    test "should be able to create new Music::Category" do
      category = Music::Category.new(
        name: "Jazz",
        category_type: "genre",
        import_source: "musicbrainz"
      )
      assert category.valid?
      assert_equal "Music::Category", category.type
    end

    test "should scope to Music::Category only" do
      music_categories = Music::Category.all
      music_categories.each do |category|
        assert_equal "Music::Category", category.type
      end

      # Should not include Movies::Category
      assert_not_includes music_categories, categories(:movies_horror_genre)
    end

    test "should have music-specific associations" do
      assert_respond_to @rock_genre, :albums
      assert_respond_to @rock_genre, :songs
      assert_respond_to @rock_genre, :artists

      # Test that associations return correct types
      assert_kind_of ActiveRecord::Associations::CollectionProxy, @rock_genre.albums
      assert_kind_of ActiveRecord::Associations::CollectionProxy, @rock_genre.songs
      assert_kind_of ActiveRecord::Associations::CollectionProxy, @rock_genre.artists
    end

    test "should have music-specific scopes" do
      assert_respond_to Music::Category, :by_album_ids
      assert_respond_to Music::Category, :by_song_ids
      assert_respond_to Music::Category, :by_artist_ids

      # Test the scopes work with actual data
      album_ids = [music_albums(:dark_side_of_the_moon).id]
      categories_with_album = Music::Category.by_album_ids(album_ids)
      assert_includes categories_with_album, @rock_genre
    end

    test "should allow FriendlyId scoped finding" do
      found = Music::Category.friendly.find("rock")
      assert_equal @rock_genre, found
    end

    test "should allow same slug as other media types" do
      # Both Music and Movies can have "horror" categories
      music_horror = Music::Category.create!(
        name: "Horror",
        category_type: "genre"
      )

      movies_horror = categories(:movies_horror_genre)

      assert_equal "horror", music_horror.slug
      assert_equal "horror", movies_horror.slug

      # But they should be findable separately by STI type
      assert_equal music_horror, Music::Category.friendly.find("horror")
      assert_equal movies_horror, Movies::Category.friendly.find("horror")
    end
  end
end
