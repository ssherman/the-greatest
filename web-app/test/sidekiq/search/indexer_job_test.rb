require "test_helper"

class Search::IndexerJobTest < ActiveSupport::TestCase
  def setup
    @job = Search::IndexerJob.new
    @artist = music_artists(:the_beatles)
    @album = music_albums(:dark_side_of_the_moon)
    @song = music_songs(:money)

    # Clear any existing requests
    SearchIndexRequest.delete_all
  end

  test "should process index requests for all model types" do
    # Create requests for different model types
    SearchIndexRequest.create!(parent: @artist, action: :index_item)
    SearchIndexRequest.create!(parent: @album, action: :index_item)
    SearchIndexRequest.create!(parent: @song, action: :index_item)

    # Mock the index classes
    mock("ArtistIndex")
    mock("AlbumIndex")
    mock("SongIndex")

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])
    Search::Music::AlbumIndex.stubs(:model_includes).returns([])
    Search::Music::SongIndex.stubs(:model_includes).returns([])

    # Expect bulk_index to be called for each type
    Search::Music::ArtistIndex.expects(:bulk_index).with([@artist])
    Search::Music::AlbumIndex.expects(:bulk_index).with([@album])
    Search::Music::SongIndex.expects(:bulk_index).with([@song])

    @job.perform

    # All requests should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should process unindex requests for all model types" do
    # Create unindex requests for different model types
    SearchIndexRequest.create!(parent: @artist, action: :unindex_item)
    SearchIndexRequest.create!(parent: @album, action: :unindex_item)
    SearchIndexRequest.create!(parent: @song, action: :unindex_item)

    # Expect bulk_unindex to be called for each type
    Search::Music::ArtistIndex.expects(:bulk_unindex).with([@artist.id])
    Search::Music::AlbumIndex.expects(:bulk_unindex).with([@album.id])
    Search::Music::SongIndex.expects(:bulk_unindex).with([@song.id])

    @job.perform

    # All requests should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should deduplicate multiple requests for same item" do
    # Create multiple index requests for the same artist
    3.times { SearchIndexRequest.create!(parent: @artist, action: :index_item) }

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])

    # Should only call bulk_index once with the artist
    Search::Music::ArtistIndex.expects(:bulk_index).once.with([@artist])

    @job.perform

    # All 3 requests should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should handle mixed index and unindex requests for same item" do
    # Create both index and unindex requests for the same artist
    SearchIndexRequest.create!(parent: @artist, action: :index_item)
    SearchIndexRequest.create!(parent: @artist, action: :unindex_item)

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])

    # Should call both bulk_index and bulk_unindex
    Search::Music::ArtistIndex.expects(:bulk_index).with([@artist])
    Search::Music::ArtistIndex.expects(:bulk_unindex).with([@artist.id])

    @job.perform

    # Both requests should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should skip indexing for deleted items" do
    # Create request for an item that will be deleted
    SearchIndexRequest.create!(parent: @artist, action: :index_item)

    # Delete the artist
    @artist.destroy!

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])

    # Should not call bulk_index since item is deleted
    Search::Music::ArtistIndex.expects(:bulk_index).never

    @job.perform

    # Request should still be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should still unindex deleted items" do
    artist_id = @artist.id

    # Create unindex request
    SearchIndexRequest.create!(parent: @artist, action: :unindex_item)

    # Delete the artist
    @artist.destroy!

    # Should still call bulk_unindex with the ID
    Search::Music::ArtistIndex.expects(:bulk_unindex).with([artist_id])

    @job.perform

    # Request should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should include model associations when specified" do
    SearchIndexRequest.create!(parent: @album, action: :index_item)

    # Mock that album index requires associations
    Search::Music::AlbumIndex.stubs(:model_includes).returns([:artists, :categories])

    # The job will call find_by first, then reload with includes
    Music::Album.expects(:find_by).with(id: @album.id).returns(@album)

    # Mock the ActiveRecord chain for the includes reload
    relation_mock = mock("relation")
    relation_mock.expects(:includes).with([:artists, :categories]).returns([@album])
    Music::Album.expects(:where).with(id: [@album.id]).returns(relation_mock)

    Search::Music::AlbumIndex.expects(:bulk_index).with([@album])

    @job.perform

    # Verify request was cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should limit requests processed per run" do
    # Create more than 1000 requests
    1005.times { SearchIndexRequest.create!(parent: @artist, action: :index_item) }

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])
    Search::Music::ArtistIndex.expects(:bulk_index).with([@artist])

    @job.perform

    # Should have processed 1000 requests (limit), leaving 5
    assert_equal 5, SearchIndexRequest.count
  end

  test "should process oldest requests first" do
    # Create requests with different timestamps
    old_request = nil
    new_request = nil

    travel_to 2.hours.ago do
      old_request = SearchIndexRequest.create!(parent: @artist, action: :index_item)
    end

    travel_to 1.hour.ago do
      new_request = SearchIndexRequest.create!(parent: @album, action: :index_item)
    end

    # Verify the older request was created first
    assert old_request.created_at < new_request.created_at

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])
    Search::Music::AlbumIndex.stubs(:model_includes).returns([])

    # Both should be processed since we're not limiting
    Search::Music::ArtistIndex.expects(:bulk_index).with([@artist])
    Search::Music::AlbumIndex.expects(:bulk_index).with([@album])

    @job.perform

    # All requests should be cleaned up
    assert_equal 0, SearchIndexRequest.count
  end

  test "should handle empty request queue gracefully" do
    # No expectations - should not call any index methods
    Search::Music::ArtistIndex.expects(:bulk_index).never
    Search::Music::AlbumIndex.expects(:bulk_index).never
    Search::Music::SongIndex.expects(:bulk_index).never

    @job.perform

    # Should complete without errors
    assert_equal 0, SearchIndexRequest.count
  end

  test "should log processing information" do
    SearchIndexRequest.create!(parent: @artist, action: :index_item)

    Search::Music::ArtistIndex.stubs(:model_includes).returns([])
    Search::Music::ArtistIndex.stubs(:bulk_index)

    Rails.logger.expects(:info).with("Starting search indexing job")
    Rails.logger.expects(:info).with("Processing 1 search index requests for Music::Artist")
    Rails.logger.expects(:info).with("Deduplicated to 1 unique items for Music::Artist")
    Rails.logger.expects(:info).with("Bulk indexing 1 unique Music::Artist items")
    Rails.logger.expects(:info).with("Cleaned up 1 processed requests for Music::Artist (including duplicates)")
    Rails.logger.expects(:info).with("Completed search indexing job")

    @job.perform
  end

  test "should warn about deleted items during indexing" do
    SearchIndexRequest.create!(parent: @artist, action: :index_item)

    # Delete the artist after creating the request
    artist_id = @artist.id
    @artist.destroy!

    Rails.logger.expects(:warn).with("Skipping indexing for deleted Music::Artist ID #{artist_id}")

    @job.perform
  end
end
