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

    desc "Diagnose list import issues - find duplicates in items_json. Usage: LIST_ID=123 bin/rails music:songs:diagnose_list_import"
    task diagnose_list_import: :environment do
      list_id = ENV["LIST_ID"]

      unless list_id
        puts "ERROR: Please provide LIST_ID"
        puts "Usage: LIST_ID=123 bin/rails music:songs:diagnose_list_import"
        exit 1
      end

      list = Music::Songs::List.find(list_id)

      puts "=" * 80
      puts "LIST IMPORT DIAGNOSTIC FOR: #{list.name}"
      puts "=" * 80

      songs = list.items_json["songs"]
      puts "\nTotal songs in items_json: #{songs.length}"

      song_ids = songs.map { |s| s["song_id"] }.compact
      song_id_counts = song_ids.group_by(&:itself).transform_values(&:count)
      duplicates_by_song_id = song_id_counts.select { |k, v| v > 1 }

      if duplicates_by_song_id.any?
        puts "\n🔍 DUPLICATE song_ids found:"
        duplicates_by_song_id.each do |id, count|
          song = Music::Song.find_by(id: id)
          puts "  - Song ID #{id} (#{song&.title || "unknown"}) appears #{count} times"
        end
        total_duplicate_songs = duplicates_by_song_id.values.sum - duplicates_by_song_id.keys.length
        puts "  Total extra occurrences: #{total_duplicate_songs}"
      end

      mb_ids = songs.map { |s| s["mb_recording_id"] }.compact
      mb_id_counts = mb_ids.group_by(&:itself).transform_values(&:count)
      duplicates_by_mb_id = mb_id_counts.select { |k, v| v > 1 }

      if duplicates_by_mb_id.any?
        puts "\n🔍 DUPLICATE mb_recording_ids found:"
        duplicates_by_mb_id.each do |id, count|
          puts "  - MusicBrainz ID #{id} appears #{count} times"
        end
        total_duplicate_mb = duplicates_by_mb_id.values.sum - duplicates_by_mb_id.keys.length
        puts "  Total extra occurrences: #{total_duplicate_mb}"
      end

      existing_count = list.list_items.count
      puts "\n📊 Current list_items in database: #{existing_count}"

      missing = songs.length - existing_count

      puts "\nExpected list_items (if no duplicates): #{songs.length}"
      puts "Actual list_items: #{existing_count}"
      puts "Missing: #{missing}"

      if duplicates_by_song_id.any? || duplicates_by_mb_id.any?
        puts "\n✅ LIKELY CAUSE: Duplicate songs in items_json"
        puts "   The importer skips creating duplicate list_items for songs already in the list."
      else
        puts "\n⚠️  No duplicates found - checking other causes..."

        invalid_songs = songs.select { |s| s["ai_match_invalid"] == true }
        puts "Songs flagged as ai_match_invalid: #{invalid_songs.length}"

        unenriched = songs.reject { |s| s["song_id"] || s["mb_recording_id"] }
        puts "Songs without song_id or mb_recording_id: #{unenriched.length}"
      end

      puts "\n" + "=" * 80
    end

    desc "Backfill release_year from MusicBrainz for songs with recording IDs. Use DRY_RUN=true to preview."
    task backfill_release_years: :environment do
      dry_run = ENV["DRY_RUN"].present? && ENV["DRY_RUN"].downcase == "true"

      puts "Backfilling release years from MusicBrainz..."
      puts "Scope: Only songs with MusicBrainz recording IDs"
      puts "Mode: #{dry_run ? "DRY RUN (no changes will be made)" : "LIVE (updates will be applied)"}"
      puts "=" * 80

      stats = {total: 0, updated: 0, skipped: 0, errors: 0}
      recording_search = Music::Musicbrainz::Search::RecordingSearch.new

      # Find songs with MusicBrainz recording IDs
      songs_with_mbid = Music::Song
        .joins(:identifiers)
        .where(identifiers: {identifier_type: :music_musicbrainz_recording_id})
        .distinct
        .includes(:identifiers, :artists)

      songs_with_mbid.find_each do |song|
        stats[:total] += 1

        # Get ALL MusicBrainz recording IDs for this song
        mbids = song.identifiers.where(identifier_type: :music_musicbrainz_recording_id).pluck(:value)
        next if mbids.empty?

        begin
          # Look up all MBIDs and find the minimum year
          mb_year = nil
          lookup_failures = 0
          mbids.each do |mbid|
            result = recording_search.lookup_by_mbid(mbid)
            unless result[:success] && result[:data]
              lookup_failures += 1
              next
            end

            recording = result[:data]["recordings"]&.first
            first_release_date = recording&.dig("first-release-date")
            next unless first_release_date.present?

            # Extract year from date (formats: YYYY, YYYY-MM, YYYY-MM-DD)
            year = first_release_date.to_s[0..3].to_i
            next if year < 1900 || year > Date.current.year + 1

            mb_year = year if mb_year.nil? || year < mb_year
          end

          # If ALL lookups failed, count as error not skip
          if lookup_failures == mbids.count
            puts "  Song ##{song.id} \"#{song.title}\" - ERROR: All #{mbids.count} MusicBrainz lookup(s) failed"
            stats[:errors] += 1
            next
          end

          unless mb_year
            puts "  Song ##{song.id} \"#{song.title}\" - SKIPPED (no valid MusicBrainz date from #{mbids.count - lookup_failures} successful lookup(s))"
            stats[:skipped] += 1
            next
          end

          current_year = song.release_year
          artist_names = song.artists.map(&:name).join(", ")

          if current_year.nil?
            puts "  Song ##{song.id} \"#{song.title}\" (#{artist_names})"
            puts "    Current: nil, MusicBrainz: #{mb_year} → #{dry_run ? "WOULD UPDATE" : "UPDATED"} (was null)"
            song.update!(release_year: mb_year) unless dry_run
            stats[:updated] += 1
          elsif mb_year < current_year
            puts "  Song ##{song.id} \"#{song.title}\" (#{artist_names})"
            puts "    Current: #{current_year}, MusicBrainz: #{mb_year} → #{dry_run ? "WOULD UPDATE" : "UPDATED"} (#{current_year - mb_year} years earlier)"
            song.update!(release_year: mb_year) unless dry_run
            stats[:updated] += 1
          else
            stats[:skipped] += 1
          end
        rescue => e
          puts "  Song ##{song.id} \"#{song.title}\" - ERROR: #{e.message}"
          stats[:errors] += 1
        end

        if stats[:total] % 100 == 0
          puts "  Processed #{stats[:total]} songs..."
        end
      end

      puts "=" * 80
      puts "Backfill complete!"
      puts "  Total processed: #{stats[:total]}"
      puts "  Updated: #{stats[:updated]}"
      puts "  Skipped (not earlier or no MB data): #{stats[:skipped]}"
      puts "  Errors: #{stats[:errors]}"

      if dry_run
        puts "\nDRY RUN - No changes were made."
        puts "To apply updates, run: bin/rails music:songs:backfill_release_years"
      end
    end
  end
end
