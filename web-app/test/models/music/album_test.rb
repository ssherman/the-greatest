# == Schema Information
#
# Table name: music_albums
#
#  id                :bigint           not null, primary key
#  description       :text
#  release_year      :integer
#  slug              :string           not null
#  title             :string           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  primary_artist_id :bigint           not null
#
# Indexes
#
#  index_music_albums_on_primary_artist_id  (primary_artist_id)
#  index_music_albums_on_slug               (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (primary_artist_id => music_artists.id)
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

    test "should require primary_artist" do
      @album.primary_artist = nil
      assert_not @album.valid?
      assert_includes @album.errors[:primary_artist], "can't be blank"
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

    # Associations
    test "should belong to primary_artist" do
      assert_respond_to @album, :primary_artist
      assert_equal @artist, @album.primary_artist
    end

    # FriendlyId (basic integration)
    test "should find by slug" do
      found = Music::Album.friendly.find(@album.slug)
      assert_equal @album, found
    end

    # SearchIndexable concern tests
    test "should create search index request on create" do
      artist = music_artists(:pink_floyd)

      assert_difference "SearchIndexRequest.count", 1 do
        Music::Album.create!(title: "Test Album", primary_artist: artist)
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
      artist = music_artists(:pink_floyd)

      assert_no_difference "SearchIndexRequest.count" do
        Music::Album.create!(title: nil, primary_artist: artist) # Invalid - title is required
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
      assert_equal album.primary_artist.name, indexed_data[:primary_artist_name]
      assert_equal album.primary_artist_id, indexed_data[:artist_id]
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
