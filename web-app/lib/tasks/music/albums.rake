namespace :music do
  namespace :albums do
    desc "Find and display duplicate albums (same title and artists). Use MERGE=true to auto-merge duplicates."
    task find_duplicates: :environment do
      auto_merge = ENV["MERGE"].present? && ENV["MERGE"].downcase == "true"

      puts "Finding duplicate albums..."
      if auto_merge
        puts "AUTO-MERGE MODE ENABLED - Will merge duplicates keeping lowest ID album"
      else
        puts "DRY RUN MODE - Use MERGE=true to actually merge duplicates"
      end
      puts "=" * 80

      duplicates = Music::Album.find_duplicates

      if duplicates.empty?
        puts "No duplicate albums found!"
      else
        puts "Found #{duplicates.count} duplicate album groups:\n\n"

        merge_success_count = 0
        merge_failure_count = 0

        duplicates.each_with_index do |duplicate_group, index|
          # Sort by ID to ensure lowest ID is first (the one we keep)
          sorted_group = duplicate_group.sort_by(&:id)
          target_album = sorted_group.first
          source_albums = sorted_group[1..]

          puts "Duplicate Group #{index + 1}:"
          puts "-" * 80
          puts "TARGET (keeping): ID #{target_album.id}"

          sorted_group.each do |album|
            artist_names = album.artists.map(&:name).join(", ")
            release_count = album.releases.count
            is_target = album.id == target_album.id

            puts "  #{is_target ? "✓ KEEP" : "✗ MERGE"} ID: #{album.id}"
            puts "  Title: #{album.title}"
            puts "  Artists: #{artist_names}"
            puts "  Release Year: #{album.release_year || "N/A"}"
            puts "  Releases: #{release_count}"
            puts "  Slug: #{album.slug}"
            puts ""
          end

          if auto_merge
            puts "  Merging #{source_albums.count} duplicate(s) into ID #{target_album.id}..."

            source_albums.each do |source_album|
              result = Music::Album::Merger.call(
                source: source_album,
                target: target_album
              )

              if result.success?
                puts "    ✓ Successfully merged ID #{source_album.id} into ID #{target_album.id}"
                merge_success_count += 1
              else
                puts "    ✗ Failed to merge ID #{source_album.id}: #{result.errors.join(", ")}"
                merge_failure_count += 1
              end
            end
          end
        end

        puts "=" * 80
        puts "Total duplicate albums found: #{duplicates.sum(&:count)}"
        puts "Duplicate groups: #{duplicates.count}"

        if auto_merge
          puts "MERGE RESULTS:"
          puts "  Successful merges: #{merge_success_count}"
          puts "  Failed merges: #{merge_failure_count}"
        else
          puts "DRY RUN - No albums were merged."
          puts "To actually merge these duplicates, run:"
          puts "  MERGE=true bin/rails music:albums:find_duplicates"
        end
      end
    end

    desc "Backfill release_year from MusicBrainz for albums with release group IDs. Use DRY_RUN=true to preview."
    task backfill_release_years: :environment do
      dry_run = ENV["DRY_RUN"].present? && ENV["DRY_RUN"].downcase == "true"

      puts "Backfilling release years from MusicBrainz..."
      puts "Scope: Only albums with MusicBrainz release group IDs"
      puts "Mode: #{dry_run ? "DRY RUN (no changes will be made)" : "LIVE (updates will be applied)"}"
      puts "=" * 80

      stats = {total: 0, updated: 0, skipped: 0, errors: 0}
      release_group_search = Music::Musicbrainz::Search::ReleaseGroupSearch.new

      # Find albums with MusicBrainz release group IDs
      albums_with_mbid = Music::Album
        .joins(:identifiers)
        .where(identifiers: {identifier_type: :music_musicbrainz_release_group_id})
        .distinct
        .includes(:identifiers, :artists)

      albums_with_mbid.find_each do |album|
        stats[:total] += 1

        # Get ALL MusicBrainz release group IDs for this album
        mbids = album.identifiers.where(identifier_type: :music_musicbrainz_release_group_id).pluck(:value)
        next if mbids.empty?

        begin
          # Look up all MBIDs and find the minimum year
          mb_year = nil
          lookup_failures = 0
          mbids.each do |mbid|
            result = release_group_search.lookup_by_release_group_mbid(mbid)
            unless result[:success] && result[:data]
              lookup_failures += 1
              next
            end

            release_group = result[:data]["release-groups"]&.first
            first_release_date = release_group&.dig("first-release-date")
            next unless first_release_date.present?

            # Extract year from date (formats: YYYY, YYYY-MM, YYYY-MM-DD)
            year = first_release_date.to_s[0..3].to_i
            next if year < 1900 || year > Date.current.year + 1

            mb_year = year if mb_year.nil? || year < mb_year
          end

          # If ALL lookups failed, count as error not skip
          if lookup_failures == mbids.count
            puts "  Album ##{album.id} \"#{album.title}\" - ERROR: All #{mbids.count} MusicBrainz lookup(s) failed"
            stats[:errors] += 1
            next
          end

          unless mb_year
            puts "  Album ##{album.id} \"#{album.title}\" - SKIPPED (no valid MusicBrainz date from #{mbids.count - lookup_failures} successful lookup(s))"
            stats[:skipped] += 1
            next
          end

          current_year = album.release_year
          artist_names = album.artists.map(&:name).join(", ")

          if current_year.nil?
            puts "  Album ##{album.id} \"#{album.title}\" (#{artist_names})"
            puts "    Current: nil, MusicBrainz: #{mb_year} → #{dry_run ? "WOULD UPDATE" : "UPDATED"} (was null)"
            album.update!(release_year: mb_year) unless dry_run
            stats[:updated] += 1
          elsif mb_year < current_year
            puts "  Album ##{album.id} \"#{album.title}\" (#{artist_names})"
            puts "    Current: #{current_year}, MusicBrainz: #{mb_year} → #{dry_run ? "WOULD UPDATE" : "UPDATED"} (#{current_year - mb_year} years earlier)"
            album.update!(release_year: mb_year) unless dry_run
            stats[:updated] += 1
          else
            stats[:skipped] += 1
          end
        rescue => e
          puts "  Album ##{album.id} \"#{album.title}\" - ERROR: #{e.message}"
          stats[:errors] += 1
        end

        if stats[:total] % 100 == 0
          puts "  Processed #{stats[:total]} albums..."
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
        puts "To apply updates, run: bin/rails music:albums:backfill_release_years"
      end
    end
  end
end
