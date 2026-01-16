# frozen_string_literal: true

namespace :lists do
  namespace :acclaimed do
    desc "Validate acclaimed music lists file. Usage: FILE_PATH=path/to/file.txt bin/rails lists:acclaimed:validate"
    task validate: :environment do
      file_path = ENV["FILE_PATH"] || default_file_path

      unless File.exist?(file_path)
        puts "ERROR: File not found: #{file_path}"
        exit 1
      end

      puts "=" * 80
      puts "ACCLAIMED LISTS VALIDATION"
      puts "=" * 80
      puts "File: #{file_path}"
      puts

      results = parse_and_validate_file(file_path)

      display_validation_results(results)
    end

    desc "Import acclaimed music lists. Usage: FILE_PATH=path/to/file.txt DRY_RUN=true bin/rails lists:acclaimed:import"
    task import: :environment do
      file_path = ENV["FILE_PATH"] || default_file_path
      dry_run = ENV["DRY_RUN"] == "true"

      unless File.exist?(file_path)
        puts "ERROR: File not found: #{file_path}"
        exit 1
      end

      puts "=" * 80
      puts "ACCLAIMED LISTS IMPORT"
      puts "=" * 80
      puts "File: #{file_path}"
      puts "Mode: #{dry_run ? "DRY RUN" : "LIVE IMPORT"}"
      puts

      results = parse_and_validate_file(file_path)

      puts "Validation Results:"
      puts "  Fully valid: #{results[:valid].count}"
      puts "  Missing country: #{results[:missing_country].count}"
      puts "  Missing year: #{results[:missing_year].count}"
      puts "  Ambiguous type: #{results[:ambiguous].count}"
      puts "  Unparseable: #{results[:invalid].count}"
      puts

      if results[:invalid].any?
        puts "WARNING: #{results[:invalid].count} unparseable entries will be skipped"
        puts "Run lists:acclaimed:validate to see details"
        puts
      end

      # Combine all importable entries (ambiguous entries are skipped during import)
      importable = results[:valid] + results[:missing_country] + results[:missing_year]
      import_results = import_lists(importable, dry_run, results[:ambiguous].count)

      # Write ambiguous and unparseable entries to a separate file
      skipped_entries = results[:ambiguous] + results[:invalid]
      if skipped_entries.any?
        skipped_file = write_skipped_entries(skipped_entries, dry_run)
        import_results[:skipped_file] = skipped_file
      end

      display_import_results(import_results, dry_run)
    end

    desc "Import manually classified skipped entries. Usage: DRY_RUN=true bin/rails lists:acclaimed:import_skipped"
    task import_skipped: :environment do
      file_path = Rails.root.join("db", "data", "acclaimed_lists_skipped.txt").to_s
      dry_run = ENV["DRY_RUN"] == "true"

      unless File.exist?(file_path)
        puts "ERROR: File not found: #{file_path}"
        puts "Run lists:acclaimed:import first to generate the skipped entries file"
        exit 1
      end

      puts "=" * 80
      puts "IMPORT SKIPPED ENTRIES"
      puts "=" * 80
      puts "File: #{file_path}"
      puts "Mode: #{dry_run ? "DRY RUN" : "LIVE IMPORT"}"
      puts

      entries = parse_skipped_file(file_path)

      puts "Parsed #{entries[:valid].count} classified entries"
      puts "  Song lists: #{entries[:valid].count { |e| e[:list_type] == :song }}"
      puts "  Album lists: #{entries[:valid].count { |e| e[:list_type] == :album }}"
      puts "  Still unclassified: #{entries[:unclassified].count}"
      puts

      if entries[:unclassified].any?
        puts "WARNING: #{entries[:unclassified].count} entries still need [SONG] or [ALBUM] prefix"
        entries[:unclassified].first(5).each do |entry|
          puts "  - #{entry[:line]}"
        end
        puts "  ..." if entries[:unclassified].count > 5
        puts
      end

      import_results = import_lists(entries[:valid], dry_run, entries[:unclassified].count)
      display_import_results(import_results, dry_run)
    end

    private

    def parse_skipped_file(file_path)
      results = {valid: [], unclassified: []}

      File.readlines(file_path, chomp: true).each_with_index do |line, index|
        line_number = index + 1

        # Skip empty lines and comments
        next if line.strip.empty? || line.strip.start_with?("#")

        # Check for [SONG] or [ALBUM] prefix
        if line =~ /^\[SONG\]\s*(.+)$/
          parsed = parse_line($1, line_number)
          parsed[:list_type] = :song
          results[:valid] << parsed
        elsif line =~ /^\[ALBUM\]\s*(.+)$/
          parsed = parse_line($1, line_number)
          parsed[:list_type] = :album
          results[:valid] << parsed
        else
          results[:unclassified] << {line: line, line_number: line_number}
        end
      end

      results
    end

    def default_file_path
      Rails.root.join("db", "data", "acclaimed_lists.txt").to_s
    end

    def parse_and_validate_file(file_path)
      results = {
        valid: [],
        invalid: [],
        ambiguous: [],
        missing_country: [],
        missing_year: []
      }

      File.readlines(file_path, chomp: true).each_with_index do |line, index|
        line_number = index + 1

        next if line.strip.empty? || line.strip.start_with?("#")

        parsed = parse_line(line, line_number)

        if parsed[:error]
          results[:invalid] << parsed
        elsif parsed[:list_type] == :ambiguous
          results[:ambiguous] << parsed
        elsif parsed[:country].nil?
          results[:missing_country] << parsed
        elsif parsed[:year].nil?
          results[:missing_year] << parsed
        else
          results[:valid] << parsed
        end
      end

      results
    end

    def parse_line(line, line_number)
      # Try multiple patterns in order of specificity

      # Pattern 1: Standard format with year at end
      # Example: Rolling Stone (USA) - The 500 Greatest Albums of All Time (2003)
      # Also handles: (2015, updated 2017), (2003/2007), (2004?), (1998-99)
      if (match = line.match(/^(.+?)\s*\(([A-Za-z\s\/]+)\)\s*-\s*(.+?)\s*\((\d{4})[^)]*\)$/))
        return build_result(line, line_number, match[1], match[2], match[3], match[4].to_i)
      end

      # Pattern 2: Year embedded in source (e.g., "Complete Book of the British Charts (UK, 2001) - ...")
      if (match = line.match(/^(.+?)\s*\(([A-Za-z\s\/]+),\s*(\d{4})\)\s*-\s*(.+)$/))
        return build_result(line, line_number, match[1], match[2], match[4], match[3].to_i)
      end

      # Pattern 3: No country, but has year (e.g., "Elvis Costello - 500 Albums You Need (2000)")
      if (match = line.match(/^(.+?)\s*-\s*(.+?)\s*\((\d{4})[^)]*\)$/))
        return build_result(line, line_number, match[1], nil, match[2], match[3].to_i)
      end

      # Pattern 4: Has country but no year (e.g., "All Music Guide (USA) - Album Ratings 1-5 Stars")
      if (match = line.match(/^(.+?)\s*\(([A-Za-z\s\/]+)\)\s*-\s*(.+)$/))
        return build_result(line, line_number, match[1], match[2], match[3], nil)
      end

      # Pattern 5: No country and no year (e.g., "The Rough Guide - Blues: 100 Essential CDs")
      if (match = line.match(/^(.+?)\s*-\s*(.+)$/))
        return build_result(line, line_number, match[1], nil, match[2], nil)
      end

      # Nothing matched
      {
        line: line,
        line_number: line_number,
        error: "Could not parse line"
      }
    end

    def build_result(line, line_number, source, country, name, year)
      list_type = detect_list_type(name.strip)

      {
        line: line,
        line_number: line_number,
        source: source.strip,
        country: country&.strip,
        name: name.strip,
        year: year,
        list_type: list_type
      }
    end

    def detect_list_type(list_name)
      song_keywords = %w[track song single recording]
      album_keywords = %w[album record lp disc cd]
      lowercase_name = list_name.downcase

      has_song_keyword = song_keywords.any? { |kw| lowercase_name.include?(kw) }
      has_album_keyword = album_keywords.any? { |kw| lowercase_name.include?(kw) }

      if has_song_keyword && !has_album_keyword
        :song
      elsif has_album_keyword && !has_song_keyword
        :album
      else
        :ambiguous
      end
    end

    def display_validation_results(results)
      puts "VALIDATION RESULTS"
      puts "=" * 80
      puts

      if results[:invalid].any?
        puts "UNPARSEABLE ENTRIES (#{results[:invalid].count}):"
        puts "-" * 80
        results[:invalid].each do |entry|
          puts "  Line #{entry[:line_number]}: #{entry[:error]}"
          puts "    #{entry[:line]}"
          puts
        end
      end

      if results[:missing_country].any?
        puts "MISSING COUNTRY (#{results[:missing_country].count}):"
        puts "-" * 80
        results[:missing_country].each do |entry|
          type_label = format_list_type(entry[:list_type])
          puts "  #{type_label} Line #{entry[:line_number]}: #{entry[:name]}"
          puts "    Source: #{entry[:source]}, Year: #{entry[:year] || "N/A"}"
        end
        puts
      end

      if results[:missing_year].any?
        puts "MISSING YEAR (#{results[:missing_year].count}):"
        puts "-" * 80
        results[:missing_year].each do |entry|
          type_label = format_list_type(entry[:list_type])
          puts "  #{type_label} Line #{entry[:line_number]}: #{entry[:name]}"
          puts "    Source: #{entry[:source]} (#{entry[:country]})"
        end
        puts
      end

      if results[:ambiguous].any?
        puts "AMBIGUOUS TYPE (#{results[:ambiguous].count}):"
        puts "-" * 80
        puts "Cannot determine if these are song or album lists:"
        results[:ambiguous].each do |entry|
          puts "  Line #{entry[:line_number]}: #{entry[:name]}"
          puts "    Source: #{entry[:source]} (#{entry[:country] || "N/A"}), Year: #{entry[:year] || "N/A"}"
        end
        puts
      end

      total_valid = results[:valid].count
      if total_valid > 0
        song_count = results[:valid].count { |e| e[:list_type] == :song }
        album_count = results[:valid].count { |e| e[:list_type] == :album }
        puts "FULLY VALID ENTRIES (#{total_valid}):"
        puts "  Song lists: #{song_count}"
        puts "  Album lists: #{album_count}"
        puts
      end

      total_lines = results.values.sum(&:count)
      puts "=" * 80
      puts "SUMMARY"
      puts "  Fully valid: #{results[:valid].count}"
      puts "  Missing country: #{results[:missing_country].count}"
      puts "  Missing year: #{results[:missing_year].count}"
      puts "  Ambiguous type: #{results[:ambiguous].count}"
      puts "  Unparseable: #{results[:invalid].count}"
      puts "  Total lines: #{total_lines}"
      puts "=" * 80
    end

    def format_list_type(list_type)
      case list_type
      when :song then "[SONG]"
      when :album then "[ALBUM]"
      else "[???]"
      end
    end

    def write_skipped_entries(entries, dry_run)
      output_path = Rails.root.join("db", "data", "acclaimed_lists_skipped.txt").to_s

      if dry_run
        puts "Would write #{entries.count} skipped entries to: #{output_path}"
        return output_path
      end

      File.open(output_path, "w") do |f|
        f.puts "# Skipped entries from acclaimed_lists.txt import"
        f.puts "# These entries could not be automatically classified as song or album lists"
        f.puts "# To import these, add [SONG] or [ALBUM] prefix to each line and run:"
        f.puts "#   bin/rails lists:acclaimed:import_skipped"
        f.puts "#"
        f.puts "# Format: [SONG] or [ALBUM] followed by the original line"
        f.puts ""

        entries.each do |entry|
          f.puts entry[:line]
        end
      end

      puts "Wrote #{entries.count} skipped entries to: #{output_path}"
      output_path
    end

    def import_lists(entries, dry_run, ambiguous_count = 0)
      results = {
        created: [],
        errors: [],
        ambiguous_count: ambiguous_count
      }

      entries.each do |entry|
        list_class = case entry[:list_type]
        when :song
          Music::Songs::List
        when :album
          Music::Albums::List
        end

        if dry_run
          results[:created] << {entry: entry, list: nil}
        else
          begin
            list = list_class.create!(
              name: entry[:name],
              source: entry[:source],
              source_country_origin: entry[:country],
              year_published: entry[:year],
              status: :unapproved,
              description: nil
            )
            results[:created] << {entry: entry, list: list}
          rescue => e
            results[:errors] << {entry: entry, error: e.message}
          end
        end
      end

      results
    end

    def display_import_results(results, dry_run)
      puts
      puts "=" * 80
      puts "IMPORT RESULTS"
      puts "=" * 80
      puts

      if results[:created].any?
        song_count = results[:created].count { |i| i[:entry][:list_type] == :song }
        album_count = results[:created].count { |i| i[:entry][:list_type] == :album }

        puts "#{dry_run ? "WOULD CREATE" : "CREATED"} (#{results[:created].count}):"
        puts "  Song lists: #{song_count}"
        puts "  Album lists: #{album_count}"
        puts
      end

      if results[:errors].any?
        puts "ERRORS (#{results[:errors].count}):"
        puts "-" * 80
        results[:errors].each do |item|
          entry = item[:entry]
          puts "  #{entry[:name]}"
          puts "    Error: #{item[:error]}"
        end
        puts
      end

      puts "=" * 80
      puts "SUMMARY"
      puts "  #{dry_run ? "Would create" : "Created"}: #{results[:created].count}"
      puts "  Skipped (ambiguous type): #{results[:ambiguous_count]}"
      puts "  Errors: #{results[:errors].count}"
      puts

      if dry_run
        puts "DRY RUN - No records were created"
        puts "To import, run: bin/rails lists:acclaimed:import"
      end
      puts "=" * 80
    end
  end
end
