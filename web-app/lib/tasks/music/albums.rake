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
  end
end
