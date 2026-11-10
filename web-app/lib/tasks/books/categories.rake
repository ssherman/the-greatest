namespace :books do
  namespace :categories do
    desc "Write the reviewed genre and audience definitions from config/books/genre_plan.yml into " \
      "categories.description, replacing any that differs. Dry run unless APPLY=1."
    task write_definitions: :environment do
      apply = ENV["APPLY"] == "1"
      data = ::Services::Books::Categories::Definitions.call(apply: apply).data
      data[:written].each { |name| puts "#{apply ? "wrote" : "would write"}: #{name}" }
      data[:replaced].each { |row| puts "replaced: #{row[:name]} (was #{row[:held].truncate(80).inspect})" }
      data[:missing].each { |name| puts "missing: #{name}" }
      puts "Re-run with APPLY=1 to write." unless apply
    end

    desc "Summarise the books.categories rows of a run: bin/rails \"books:categories:report[categories-v1]\" (no label = every run)"
    task :report, [:label] => :environment do |_task, args|
      data = ::Services::Books::Categories::Report.call(label: args[:label].presence).data
      pairs = ->(hash) { hash.map { |key, count| "#{key}=#{count}" }.join(", ") }
      puts "Books with a categories row: #{data[:books]}"
      puts "By outcome: #{pairs.call(data[:by_outcome])}"
      puts "Added by type: #{pairs.call(data[:added])}"
      puts "Confirmed by type: #{pairs.call(data[:confirmed])}"
      puts "Removed by type: #{pairs.call(data[:removed])}"
      puts "Held back by reason: #{pairs.call(data[:held_back])}"
      puts "Book type by reason: #{pairs.call(data[:type])}"
      puts "Average added per book: #{data[:avg_added_per_book]}; removed: #{data[:avg_removed_per_book]}"
      puts "Type conflicts (#{data[:type_conflicts].size} of #{data[:type]["type_conflict"] || 0}):"
      data[:type_conflicts].each { |c| puts "  ##{c[:book_id]} #{c[:title]}: judged #{c[:judged]}, held #{c[:held]}" }
      puts "Unmatched answers (top 20 per type):"
      data[:unmatched].each do |type, names|
        puts "  #{type}:"
        names.each { |proposed, count| puts "    #{proposed}: #{count}" }
      end
      puts "Genre names to alias (add as an alternative name on an existing genre, or ignore):"
      data[:unlisted_genres].each { |name, count| puts "  #{name}: #{count}" }
      puts "Research rows: #{data[:research_rows]} (about $#{format("%.2f", data[:research_cost_estimate])})"
      puts "Deferred research: #{data[:deferred_research]}"
    end

    desc "Put back the legacy links a run removed; APPLY=1 writes: bin/rails \"books:categories:restore_removals[categories-v1]\""
    task :restore_removals, [:label] => :environment do |_task, args|
      label = args[:label].presence
      abort "A run label is required: bin/rails \"books:categories:restore_removals[LABEL]\"" unless label
      apply = ENV["APPLY"] == "1"
      data = ::Services::Books::Categories::RestoreRemovals.call(label: label, apply: apply).data
      puts "#{apply ? "restored" : "would restore"} #{data[:links]} links on #{data[:books]} books (skipped #{data[:skipped]})"
      puts "Re-run with APPLY=1 to restore them." unless apply
    end
  end
end
