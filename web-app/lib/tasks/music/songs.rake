namespace :music do
  namespace :songs do
    desc "Find and display duplicate songs (same title and artists). Use MERGE=true to auto-merge duplicates."
    task find_duplicates: :environment do
      auto_merge = ENV["MERGE"].present? && ENV["MERGE"].downcase == "true"

      puts "Finding duplicate songs..."
      if auto_merge
        puts "AUTO-MERGE MODE ENABLED - Will merge duplicates keeping lowest ID song"
      else
        puts "DRY RUN MODE - Use MERGE=true to actually merge duplicates"
      end
      puts "=" * 80

      duplicates = Music::Song.find_duplicates

      # Count songs without artists for informational message (efficient query)
      songs_without_artists_count = Music::Song
        .left_joins(:song_artists)
        .where(music_song_artists: {id: nil})
        .count

      if duplicates.empty?
        puts "No duplicate songs found!"
        if songs_without_artists_count > 0
          puts "\nNote: #{songs_without_artists_count} songs without artist data were skipped"
          puts "(These cannot be auto-merged safely as they may be different songs)"
        end
      else
        puts "Found #{duplicates.count} duplicate song groups:\n\n"

        merge_success_count = 0
        merge_failure_count = 0

        duplicates.each_with_index do |duplicate_group, index|
          # Sort by ID to ensure lowest ID is first (the one we keep)
          sorted_group = duplicate_group.sort_by(&:id)
          target_song = sorted_group.first
          source_songs = sorted_group[1..]

          puts "Duplicate Group #{index + 1}:"
          puts "-" * 80
          puts "TARGET (keeping): ID #{target_song.id}"

          sorted_group.each do |song|
            artist_names = song.artists.map(&:name).join(", ")
            artist_names = "No artists" if artist_names.blank?
            track_count = song.tracks.count
            is_target = song.id == target_song.id

            puts "  #{is_target ? "✓ KEEP" : "✗ MERGE"} ID: #{song.id}"
            puts "  Title: #{song.title}"
            puts "  Artists: #{artist_names}"
            puts "  Release Year: #{song.release_year || "N/A"}"
            puts "  Tracks: #{track_count}"
            puts "  Slug: #{song.slug}"
            puts ""
          end

          if auto_merge
            puts "  Merging #{source_songs.count} duplicate(s) into ID #{target_song.id}..."

            source_songs.each do |source_song|
              result = Music::Song::Merger.call(
                source: source_song,
                target: target_song
              )

              if result.success?
                puts "    ✓ Successfully merged ID #{source_song.id} into ID #{target_song.id}"
                merge_success_count += 1
              else
                puts "    ✗ Failed to merge ID #{source_song.id}: #{result.errors.join(", ")}"
                merge_failure_count += 1
              end
            end
          end
        end

        puts "=" * 80
        puts "Total duplicate songs found: #{duplicates.sum(&:count)}"
        puts "Duplicate groups: #{duplicates.count}"

        if songs_without_artists_count > 0
          puts "\nNote: #{songs_without_artists_count} songs without artist data were skipped"
          puts "(These cannot be auto-merged safely as they may be different songs)"
        end

        if auto_merge
          puts "MERGE RESULTS:"
          puts "  Successful merges: #{merge_success_count}"
          puts "  Failed merges: #{merge_failure_count}"
        else
          puts "DRY RUN - No songs were merged."
          puts "To actually merge these duplicates, run:"
          puts "  MERGE=true bin/rails music:songs:find_duplicates"
        end
      end
    end
  end
end
