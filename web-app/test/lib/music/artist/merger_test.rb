require "test_helper"

module Music
  class Artist
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source_artist = music_artists(:beatles_tribute_band)
        @target_artist = music_artists(:the_beatles)

        # Clean up any ranked_items from fixtures to ensure tests start with clean state
        RankedItem.where(item: @source_artist).destroy_all
        RankedItem.where(item: @target_artist).destroy_all
      end

      test "should successfully merge artists and return success result" do
        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?, "Merger failed with errors: #{result.errors.inspect}"
        assert_equal @target_artist, result.data
        assert_empty result.errors
      end

      test "should prevent merging an artist with itself" do
        result = Music::Artist::Merger.call(source: @source_artist, target: @source_artist)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge an artist with itself"], result.errors

        assert Music::Artist.exists?(@source_artist.id)
      end

      test "should reassign album_artists to target artist" do
        album = music_albums(:dark_side_of_the_moon)
        album_artist = Music::AlbumArtist.create!(
          artist: @source_artist,
          album: album,
          position: 1
        )

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        album_artist.reload

        assert_equal @target_artist.id, album_artist.artist_id
      end

      test "should handle duplicate album_artists by destroying source" do
        album = music_albums(:dark_side_of_the_moon)

        Music::AlbumArtist.create!(
          artist: @source_artist,
          album: album,
          position: 1
        )

        Music::AlbumArtist.create!(
          artist: @target_artist,
          album: album,
          position: 1
        )

        initial_count = @target_artist.album_artists.count

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        @target_artist.reload

        assert_equal initial_count, @target_artist.album_artists.count
      end

      test "should reassign song_artists to target artist" do
        song = music_songs(:money)
        song_artist = Music::SongArtist.create!(
          artist: @source_artist,
          song: song,
          position: 1
        )

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        song_artist.reload

        assert_equal @target_artist.id, song_artist.artist_id
      end

      test "should handle duplicate song_artists by destroying source" do
        song = music_songs(:money)

        Music::SongArtist.create!(
          artist: @source_artist,
          song: song,
          position: 1
        )

        Music::SongArtist.create!(
          artist: @target_artist,
          song: song,
          position: 1
        )

        initial_count = @target_artist.song_artists.count

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        @target_artist.reload

        assert_equal initial_count, @target_artist.song_artists.count
      end

      # NOTE: Membership and credits tests removed - not currently used

      test "should reassign identifiers to target artist" do
        identifier = Identifier.create!(
          identifiable: @source_artist,
          identifier_type: :music_musicbrainz_artist_id,
          value: "test-mb-artist-123"
        )

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        identifier.reload

        assert_equal @target_artist.id, identifier.identifiable_id
        assert_equal "Music::Artist", identifier.identifiable_type
      end

      test "should handle duplicate identifiers when merging" do
        shared_id = "shared-musicbrainz-id"

        source_identifier = Identifier.create!(
          identifiable: @source_artist,
          identifier_type: :music_musicbrainz_artist_id,
          value: shared_id
        )

        target_identifier = Identifier.create!(
          identifiable: @target_artist,
          identifier_type: :music_musicbrainz_artist_id,
          value: shared_id
        )

        initial_target_count = @target_artist.identifiers.count

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        @target_artist.reload

        assert_equal initial_target_count, @target_artist.identifiers.count
        assert_not Identifier.exists?(source_identifier.id)
        assert Identifier.exists?(target_identifier.id)
      end

      test "should merge category_items with duplicate handling" do
        category = categories(:music_rock_genre)

        CategoryItem.create!(
          item: @source_artist,
          category: category
        )

        CategoryItem.create!(
          item: @target_artist,
          category: category
        )

        initial_count = @target_artist.category_items.count

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        @target_artist.reload

        assert_equal initial_count, @target_artist.category_items.count
      end

      test "should reassign images to target artist and preserve primary" do
        # Create target image with file attached
        target_image = Image.new(parent: @target_artist, primary: true)
        target_image.file.attach(
          io: StringIO.new("fake image data"),
          filename: "target.jpg",
          content_type: "image/jpeg"
        )
        target_image.save!

        # Create source image with file attached
        source_image = Image.new(parent: @source_artist, primary: true)
        source_image.file.attach(
          io: StringIO.new("fake source image"),
          filename: "source.jpg",
          content_type: "image/jpeg"
        )
        source_image.save!

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        source_image.reload
        target_image.reload

        assert_equal @target_artist.id, source_image.parent_id
        assert_not source_image.primary, "Source image should not be primary after merge"
        assert target_image.primary, "Target image should remain primary"
      end

      test "should reassign external_links to target artist" do
        external_link = ExternalLink.create!(
          parent: @source_artist,
          link_category: :product_link,
          url: "https://example.com/artist",
          name: "Artist Page"
        )

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        external_link.reload

        assert_equal @target_artist.id, external_link.parent_id
        assert_equal "Music::Artist", external_link.parent_type
      end

      test "should trigger target artist touch to queue reindex" do
        @target_artist.reload
        original_updated_at = @target_artist.updated_at

        sleep 0.01

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        @target_artist.reload

        assert_operator @target_artist.updated_at, :>, original_updated_at
      end

      test "should create search index request for target artist" do
        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        assert SearchIndexRequest.exists?(
          parent_type: "Music::Artist",
          parent_id: @target_artist.id,
          action: :index_item
        )
      end

      test "should destroy source artist after merge" do
        source_id = @source_artist.id

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        assert_not Music::Artist.exists?(source_id)
      end

      test "should schedule ranking recalculation jobs for affected configurations" do
        config = Music::Artists::RankingConfiguration.create!(
          name: "Test Ranking",
          description: "Test"
        )

        RankedItem.create!(
          item: @source_artist,
          ranking_configuration: config,
          rank: 1
        )

        BulkCalculateWeightsJob.expects(:perform_async).with(config.id)
        CalculateRankingsJob.expects(:perform_in).with(5.minutes, config.id)

        Music::Artist::Merger.call(source: @source_artist, target: @target_artist)
      end

      test "should not schedule jobs if no ranked_items exist" do
        BulkCalculateWeightsJob.expects(:perform_async).never
        CalculateRankingsJob.expects(:perform_in).never

        Music::Artist::Merger.call(source: @source_artist, target: @target_artist)
      end

      test "should return error result on exception" do
        Music::Artist::Merger.any_instance.stubs(:merge_all_associations).raises(StandardError.new("Test error"))

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Test error"], result.errors
      end

      test "should rollback on error and preserve source artist" do
        source_id = @source_artist.id

        Music::Artist::Merger.any_instance.stubs(:destroy_source_artist).raises(StandardError.new("Destruction failed"))

        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert_not result.success?
        assert Music::Artist.exists?(source_id)
      end

      test "should work with class method call syntax" do
        result = Music::Artist::Merger.call(source: @source_artist, target: @target_artist)

        assert result.success?
        assert_not Music::Artist.exists?(@source_artist.id)
      end

      test "should initialize with correct attributes" do
        merger = Music::Artist::Merger.new(source: @source_artist, target: @target_artist)

        assert_equal @source_artist, merger.source_artist
        assert_equal @target_artist, merger.target_artist
        assert_equal({}, merger.stats)
      end

      test "should handle artists with no associations" do
        bare_artist = Music::Artist.create!(name: "Bare Artist", slug: "bare-artist-test", kind: :person)
        target = Music::Artist.create!(name: "Target Artist", slug: "target-artist-test", kind: :person)

        result = Music::Artist::Merger.call(source: bare_artist, target: target)

        assert result.success?
        assert_not Music::Artist.exists?(bare_artist.id)
      end
    end
  end
end
