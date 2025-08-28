# frozen_string_literal: true

# == Schema Information
#
# Table name: search_index_requests
#
#  id          :bigint           not null, primary key
#  action      :integer          not null
#  parent_type :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  parent_id   :bigint           not null
#
# Indexes
#
#  index_search_index_requests_on_action                     (action)
#  index_search_index_requests_on_created_at                 (created_at)
#  index_search_index_requests_on_parent                     (parent_type,parent_id)
#  index_search_index_requests_on_parent_type_and_parent_id  (parent_type,parent_id)
#
require "test_helper"

class SearchIndexRequestTest < ActiveSupport::TestCase
  def setup
    @artist = music_artists(:the_beatles)
    @valid_attributes = {
      parent: @artist,
      action: :index_item
    }
  end

  test "should be valid with valid attributes" do
    request = SearchIndexRequest.new(@valid_attributes)
    assert request.valid?
  end

  test "should require action" do
    request = SearchIndexRequest.new(@valid_attributes.except(:action))
    assert_not request.valid?
    assert_includes request.errors[:action], "can't be blank"
  end

  test "should require parent" do
    request = SearchIndexRequest.new(@valid_attributes.except(:parent))
    assert_not request.valid?
    assert_includes request.errors[:parent], "must exist"
  end

  test "should require parent_type" do
    request = SearchIndexRequest.new(@valid_attributes)
    request.parent_type = nil
    assert_not request.valid?
    assert_includes request.errors[:parent_type], "can't be blank"
  end

  test "should require parent_id" do
    request = SearchIndexRequest.new(@valid_attributes)
    request.parent_id = nil
    assert_not request.valid?
    assert_includes request.errors[:parent_id], "can't be blank"
  end

  test "should accept index_item action" do
    request = SearchIndexRequest.new(@valid_attributes.merge(action: :index_item))
    assert request.valid?
    assert request.index_item?
  end

  test "should accept unindex_item action" do
    request = SearchIndexRequest.new(@valid_attributes.merge(action: :unindex_item))
    assert request.valid?
    assert request.unindex_item?
  end

  test "should work with different parent types" do
    album = music_albums(:dark_side_of_the_moon)
    song = music_songs(:time)

    artist_request = SearchIndexRequest.create!(@valid_attributes)
    album_request = SearchIndexRequest.create!(parent: album, action: :index_item)
    song_request = SearchIndexRequest.create!(parent: song, action: :index_item)

    assert_equal "Music::Artist", artist_request.parent_type
    assert_equal "Music::Album", album_request.parent_type
    assert_equal "Music::Song", song_request.parent_type
  end

  test "for_type scope should filter by parent_type" do
    album = music_albums(:dark_side_of_the_moon)

    SearchIndexRequest.create!(parent: @artist, action: :index_item)
    SearchIndexRequest.create!(parent: album, action: :index_item)

    artist_requests = SearchIndexRequest.for_type("Music::Artist")
    album_requests = SearchIndexRequest.for_type("Music::Album")

    assert_equal 1, artist_requests.count
    assert_equal 1, album_requests.count
    assert_equal @artist, artist_requests.first.parent
    assert_equal album, album_requests.first.parent
  end

  test "for_action scope should filter by action" do
    # Clear any existing requests from other tests
    SearchIndexRequest.delete_all

    album = music_albums(:dark_side_of_the_moon)

    SearchIndexRequest.create!(parent: @artist, action: :index_item)
    SearchIndexRequest.create!(parent: album, action: :unindex_item)

    index_requests = SearchIndexRequest.for_action(:index_item)
    unindex_requests = SearchIndexRequest.for_action(:unindex_item)

    assert_equal 1, index_requests.count
    assert_equal 1, unindex_requests.count
    assert index_requests.first.index_item?
    assert unindex_requests.first.unindex_item?
  end

  test "oldest_first scope should order by created_at" do
    # Create requests with different timestamps
    first_request = nil

    travel_to 1.hour.ago do
      first_request = SearchIndexRequest.create!(@valid_attributes)
    end

    second_request = SearchIndexRequest.create!(parent: music_albums(:dark_side_of_the_moon), action: :index_item)

    requests = SearchIndexRequest.oldest_first
    assert_equal first_request, requests.first
    assert_equal second_request, requests.last
  end
end
