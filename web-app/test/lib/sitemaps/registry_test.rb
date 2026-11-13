require "test_helper"

module Sitemaps
  class RegistryTest < ActiveSupport::TestCase
    test "books has no sources while public indexing is off" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(false)
      assert_equal [], Sitemaps::Registry.sources(:books)
    end

    test "books has sources once public indexing is on" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(true)
      assert_includes Sitemaps::Registry.sources(:books).map(&:key), "pages"
    end

    test "movies has no sources" do
      assert_equal [], Sitemaps::Registry.sources(:movies)
    end

    test "keys are unique and url-safe per domain" do
      ::Books::PublicIndexing.stubs(:enabled?).returns(true)
      %i[books music games].each do |d|
        keys = Sitemaps::Registry.sources(d).map(&:key)
        assert_not_empty keys
        assert_equal keys.uniq, keys
        keys.each { |k| assert_match(/\A[a-z_]+\z/, k) }
      end
    end

    test "find returns the source for a key" do
      assert_equal "news", Sitemaps::Registry.find(:music, "news").key
    end

    test "find returns nil for another domain's key" do
      assert_nil Sitemaps::Registry.find(:games, "songs")
    end

    test "sources are built fresh on every call" do
      assert_not_same Sitemaps::Registry.sources(:music).first, Sitemaps::Registry.sources(:music).first
    end

    test "page_count rounds up, honours page_size and is at least one" do
      source = Sitemaps::StaticPages.new(paths: %w[/a /b /c])
      Sitemaps::Registry.stubs(:page_size).returns(2)
      assert_equal 2, Sitemaps::Registry.page_count(source)
      Sitemaps::Registry.stubs(:page_size).returns(3)
      assert_equal 1, Sitemaps::Registry.page_count(source)
      assert_equal 1, Sitemaps::Registry.page_count(Sitemaps::StaticPages.new(paths: []))
    end

    test "music keys are exactly the music sources, in order" do
      assert_equal %w[pages news albums songs artists album_lists song_lists categories album_categories],
        Sitemaps::Registry.sources(:music).map(&:key)
    end

    test "music songs lists a ranked song and omits an unranked one" do
      paths = Sitemaps::Registry.find(:music, "songs").entries(offset: 0, limit: 1000).map(&:path)
      assert_includes paths, "/song/#{music_songs(:time).slug}"
      assert_not_includes paths, "/song/#{music_songs(:wish_you_were_here).slug}"
    end

    test "music albums and artists use their canonical prefixes" do
      album = music_albums(:dark_side_of_the_moon)
      RankedItem.create!(item: album, ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 9)
      artist = music_artists(:pink_floyd)
      RankedItem.create!(item: artist, ranking_configuration: ranking_configurations(:music_artists_global), rank: 1, score: 9)
      assert_includes Sitemaps::Registry.find(:music, "albums").entries(offset: 0, limit: 1000).map(&:path), "/album/#{album.slug}"
      assert_includes Sitemaps::Registry.find(:music, "artists").entries(offset: 0, limit: 1000).map(&:path), "/artists/#{artist.slug}"
    end

    test "music album lists list an active ranked list" do
      list = lists(:music_albums_list)
      list.update!(status: :active)
      paths = Sitemaps::Registry.find(:music, "album_lists").entries(offset: 0, limit: 1000).map(&:path)
      assert_includes paths, "/albums/lists/#{list.id}"
    end

    test "categories count ranked albums plus ranked artists, album_categories only albums" do
      category = categories(:music_rock_genre)
      Sitemaps::Thresholds.stubs(:filter_single).returns(2)
      RankedItem.create!(item: music_albums(:dark_side_of_the_moon), ranking_configuration: ranking_configurations(:music_albums_global), rank: 1, score: 9)
      CategoryItem.create!(category: category, item: music_artists(:pink_floyd))
      RankedItem.create!(item: music_artists(:pink_floyd), ranking_configuration: ranking_configurations(:music_artists_global), rank: 1, score: 9)

      both = Sitemaps::Registry.find(:music, "categories").entries(offset: 0, limit: 1000).map(&:path)
      albums_only = Sitemaps::Registry.find(:music, "album_categories").entries(offset: 0, limit: 1000).map(&:path)
      assert_includes both, "/categories/#{category.slug}"
      assert_not_includes albums_only, "/albums/categories/#{category.slug}"
    end

    test "an unranked album does not count toward a category" do
      Sitemaps::Thresholds.stubs(:filter_single).returns(1)
      category = categories(:music_rock_genre)
      RankedItem.create!(item: music_albums(:dark_side_of_the_moon), ranking_configuration: ranking_configurations(:music_albums_global), rank: nil)
      paths = Sitemaps::Registry.find(:music, "album_categories").entries(offset: 0, limit: 1000).map(&:path)
      assert_not_includes paths, "/albums/categories/#{category.slug}"
    end

    test "page_size defaults to PAGE_SIZE" do
      assert_equal 50_000, Sitemaps::Registry.page_size
    end
  end
end
