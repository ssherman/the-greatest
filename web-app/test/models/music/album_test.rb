# == Schema Information
#
# Table name: music_albums
#
#  id           :bigint           not null, primary key
#  description  :text
#  release_year :integer
#  slug         :string           not null
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_music_albums_on_release_year  (release_year)
#  index_music_albums_on_slug          (slug) UNIQUE
#
require "test_helper"

module Music
  class AlbumTest < ActiveSupport::TestCase
    def setup
      @album = music_albums(:dark_side_of_the_moon)
      @artist = music_artists(:pink_floyd)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @album.valid?
    end

    test "should require title" do
      @album.title = nil
      assert_not @album.valid?
      assert_includes @album.errors[:title], "can't be blank"
    end

    test "should have artists" do
      assert_respond_to @album, :artists
      assert_respond_to @album, :album_artists
      assert_equal [@artist], @album.artists.to_a
    end

    test "should allow description" do
      @album.description = "A classic album."
      assert @album.valid?
      assert_equal "A classic album.", @album.description
    end

    test "should allow empty description" do
      @album.description = nil
      assert @album.valid?
    end

    test "should allow nil release_year" do
      @album.release_year = nil
      assert @album.valid?
    end

    test "should require integer release_year if present" do
      @album.release_year = 1973
      assert @album.valid?
      @album.release_year = "not a year"
      assert_not @album.valid?
      assert_includes @album.errors[:release_year], "is not a number"
    end

    # Quote Normalization
    test "should normalize smart quotes in title on create" do
      Music::ImportAlbumReleasesJob.stubs(:perform_async)
      album = Music::Album.create!(title: "\u201CThe Wall\u201D")
      assert_equal "\"The Wall\"", album.title
    end

    test "should normalize smart quotes in title on update" do
      @album.update!(title: "\u2018Wish You Were Here\u2019")
      assert_equal "'Wish You Were Here'", @album.title
    end

    test "should not modify title if no smart quotes present" do
      @album.update!(title: "The Wall")
      assert_equal "The Wall", @album.title
    end

    test "should normalize quotes for new albums with proper slug generation" do
      Music::ImportAlbumReleasesJob.stubs(:perform_async)
      album = Music::Album.create!(title: "\u201CTest Unique Album\u201D")
      assert_equal "\"Test Unique Album\"", album.title
      assert_equal "test-unique-album", album.slug
    end

    # Associations
    test "should have many artists through album_artists" do
      assert_respond_to @album, :artists
      assert_respond_to @album, :album_artists
      assert_equal [@artist], @album.artists.to_a
    end

    # FriendlyId (basic integration)
    test "should find by slug" do
      found = Music::Album.friendly.find(@album.slug)
      assert_equal @album, found
    end

    # SearchIndexable concern tests
    test "should create search index request on create" do
      # Stub the release import job since we're only testing search indexing
      Music::ImportAlbumReleasesJob.stubs(:perform_async)

      artist = music_artists(:pink_floyd)
      album = nil

      assert_difference "SearchIndexRequest.count", 1 do
        album = Music::Album.create!(title: "Test Album")
        album.album_artists.create!(artist: artist)
      end

      request = SearchIndexRequest.last
      assert_equal "Music::Album", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on update" do
      album = music_albums(:dark_side_of_the_moon)

      assert_difference "SearchIndexRequest.count", 1 do
        album.update!(title: "Updated Title")
      end

      request = SearchIndexRequest.last
      assert_equal album, request.parent
      assert request.index_item?
    end

    test "should not create search index request if validation fails" do
      assert_no_difference "SearchIndexRequest.count" do
        Music::Album.create!(title: nil) # Invalid - title is required
      rescue ActiveRecord::RecordInvalid
        # Expected to fail
      end
    end

    test "should create search index request on destroy" do
      album = music_albums(:dark_side_of_the_moon)

      # When album is destroyed:
      # 1. Album creates 1 unindex_item request
      # 2. Its 3 category_items create 3 index_item requests (will be handled gracefully by job)
      assert_difference "SearchIndexRequest.count", 4 do
        album.destroy!
      end

      requests = SearchIndexRequest.last(4)

      # Should have 1 unindex request for the album
      unindex_request = requests.find(&:unindex_item?)
      assert unindex_request
      assert_equal album.id, unindex_request.parent_id
      assert_equal "Music::Album", unindex_request.parent_type

      # Should have 3 index requests from category_items (will be skipped by job since album is deleted)
      index_requests = requests.select(&:index_item?)
      assert_equal 3, index_requests.count
      index_requests.each do |request|
        assert_equal album.id, request.parent_id
        assert_equal "Music::Album", request.parent_type
      end
    end

    test "as_indexed_json should include required fields" do
      album = music_albums(:dark_side_of_the_moon)

      indexed_data = album.as_indexed_json

      assert_equal album.title, indexed_data[:title]
      assert_equal album.artists.pluck(:name), indexed_data[:artist_names]
      assert_equal album.artists.pluck(:id), indexed_data[:artist_ids]
      assert_includes indexed_data.keys, :category_ids
      assert indexed_data[:category_ids].is_a?(Array)
    end

    test "as_indexed_json should only include active categories" do
      album = music_albums(:dark_side_of_the_moon)

      # Create a category and associate it
      category = Music::Category.create!(name: "Progressive Rock", type: "Music::Category")
      CategoryItem.create!(category: category, item: album)

      # Create a deleted category and associate it
      deleted_category = Music::Category.create!(name: "Psychedelic", type: "Music::Category", deleted: true)
      CategoryItem.create!(category: deleted_category, item: album)

      indexed_data = album.as_indexed_json

      assert_includes indexed_data[:category_ids], category.id
      assert_not_includes indexed_data[:category_ids], deleted_category.id
    end
  end
end
