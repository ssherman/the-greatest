# frozen_string_literal: true

namespace :search do
  namespace :music do
    desc "Recreate and reindex all music indices (Artists, Albums, Songs)"
    task recreate_and_reindex_all: :environment do
      puts "=" * 80
      puts "Search Music Indices - Recreation and Reindexing"
      puts "=" * 80
      puts "\nThis will delete existing indices and recreate them with updated mappings.\n\n"

      indices = [
        {klass: Search::Music::ArtistIndex, name: "Artists", model: Music::Artist},
        {klass: Search::Music::AlbumIndex, name: "Albums", model: Music::Album},
        {klass: Search::Music::SongIndex, name: "Songs", model: Music::Song}
      ]

      indices.each do |index_info|
        record_count = index_info[:model].count
        puts "[#{index_info[:name]}] Starting recreation and reindex (#{record_count} records to index)..."

        # reindex_all handles: delete_index (if exists) + create_index + bulk_index
        index_info[:klass].reindex_all

        puts "[#{index_info[:name]}] ✓ Complete!"
      end

      puts "\n" + "=" * 80
      puts "All music indices recreated and reindexed successfully!"
      puts "=" * 80
    end

    desc "Recreate Artists index"
    task recreate_artists: :environment do
      record_count = Music::Artist.count
      puts "Recreating Artists index (#{record_count} records)..."
      Search::Music::ArtistIndex.reindex_all
      puts "✓ Artists index recreated and reindexed"
    end

    desc "Recreate Albums index"
    task recreate_albums: :environment do
      record_count = Music::Album.count
      puts "Recreating Albums index (#{record_count} records)..."
      Search::Music::AlbumIndex.reindex_all
      puts "✓ Albums index recreated and reindexed"
    end

    desc "Recreate Songs index"
    task recreate_songs: :environment do
      record_count = Music::Song.count
      puts "Recreating Songs index (#{record_count} records)..."
      Search::Music::SongIndex.reindex_all
      puts "✓ Songs index recreated and reindexed"
    end
  end
end
