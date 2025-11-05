namespace :music do
  desc "Normalize quote characters in song titles, album titles, and artist names"
  task normalize_names: :environment do
    dry_run = ENV["DRY_RUN"] == "true"

    puts "=" * 80
    puts "Music Name/Title Quote Normalization"
    puts "=" * 80
    puts "Running in #{dry_run ? "DRY RUN" : "LIVE"} mode"
    puts "Started at: #{Time.current}"
    puts

    stats = {
      songs: normalize_model(Music::Song, :title, dry_run),
      albums: normalize_model(Music::Album, :title, dry_run),
      artists: normalize_model(Music::Artist, :name, dry_run)
    }

    puts
    puts "=" * 80
    puts "Summary"
    puts "=" * 80
    puts "Songs:"
    puts "  Total: #{stats[:songs][:total]}"
    puts "  Changed: #{stats[:songs][:changed]}"
    puts "  Unchanged: #{stats[:songs][:unchanged]}"
    puts "  Errors: #{stats[:songs][:errors]}"
    puts
    puts "Albums:"
    puts "  Total: #{stats[:albums][:total]}"
    puts "  Changed: #{stats[:albums][:changed]}"
    puts "  Unchanged: #{stats[:albums][:unchanged]}"
    puts "  Errors: #{stats[:albums][:errors]}"
    puts
    puts "Artists:"
    puts "  Total: #{stats[:artists][:total]}"
    puts "  Changed: #{stats[:artists][:changed]}"
    puts "  Unchanged: #{stats[:artists][:unchanged]}"
    puts "  Errors: #{stats[:artists][:errors]}"
    puts
    puts "Completed at: #{Time.current}"
    puts "=" * 80
  end

  private

  def normalize_model(model_class, field, dry_run)
    stats = {total: 0, changed: 0, unchanged: 0, errors: 0}
    model_name = model_class.name.demodulize

    puts "Processing #{model_name.pluralize}..."

    model_class.find_each do |record|
      stats[:total] += 1

      begin
        original_value = record.public_send(field)
        normalized_value = Services::Text::QuoteNormalizer.call(original_value)

        if original_value != normalized_value
          stats[:changed] += 1

          unless dry_run
            record.update!(field => normalized_value)
          end

          if stats[:changed] <= 10
            puts "  #{model_name} ##{record.id}: '#{original_value}' -> '#{normalized_value}'"
          elsif stats[:changed] == 11
            puts "  ... (showing first 10 changes)"
          end
        else
          stats[:unchanged] += 1
        end
      rescue => e
        stats[:errors] += 1
        puts "  ERROR processing #{model_name} ##{record.id}: #{e.message}"
      end

      if stats[:total] % 100 == 0
        print "  Processed #{stats[:total]} #{model_name.pluralize.downcase}...\r"
      end
    end

    puts "  Processed #{stats[:total]} #{model_name.pluralize.downcase} - Complete"
    puts

    stats
  end
end
