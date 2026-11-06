namespace :books do
  namespace :categorize do
    desc "Plan the origin backfill, paced one book every 8 seconds, ranked books first. Dry run by default; " \
      "APPLY=1 queues Books::CategorizeBackfillJob. BOOK_IDS=1,2,3 restricts it (for the rehearsal): " \
      "bin/rails \"books:categorize:backfill[origin_only,all,origin-v1]\""
    task :backfill, [:scope, :limit, :label] => :environment do |_task, args|
      scope = args[:scope].to_s.strip
      refusal = ::Services::Books::Categorize::Backfill.refusal(scope)
      abort "books:categorize:backfill: #{refusal}" if refusal

      raw = args[:limit].to_s.strip
      limit = (raw == "all") ? nil : Integer(raw, exception: false)
      unless raw == "all" || limit&.positive?
        abort "Usage: bin/rails \"books:categorize:backfill[origin_only,limit,label]\" -- limit is a number or all"
      end
      label = args[:label].to_s.strip
      abort "books:categorize:backfill: a label is required (it names this run in the report)" if label.empty?
      book_ids = ENV["BOOK_IDS"].to_s.split(",").map(&:strip).reject(&:empty?).map { Integer(it) }.presence

      relation = ::Services::Books::Categorize::Backfill.candidates(scope: scope, book_ids: book_ids)
      relation = relation.limit(limit) if limit
      count = relation.count
      spacing = ::Services::Books::Categorize::Backfill::SPACING
      hours = (count * spacing / 3600.0).round(1)

      if ENV["APPLY"] == "1"
        Books::CategorizeBackfillJob.perform_async(scope, limit, label, book_ids)
        puts "Queued Books::CategorizeBackfillJob for #{count} books (scope #{scope}, label #{label}); about #{hours} hours of Wikimedia pacing. Progress: the worker log."
      else
        puts "#{count} books would be planned (scope #{scope}, label #{label}); about #{hours} hours of Wikimedia pacing. Re-run with APPLY=1 to queue Books::CategorizeBackfillJob."
      end
    end
  end

  namespace :origin do
    desc "Summarise the books.origin rows of a run: bin/rails \"books:origin:report[origin-v1]\" (no label = every run)"
    task :report, [:label] => :environment do |_task, args|
      data = ::Services::Books::Origin::Report.call(label: args[:label].presence).data
      puts "Books with an origin row: #{data[:books]}"
      puts "By path: #{data[:by_path].map { |key, count| "#{key}=#{count}" }.join(", ")}"
      puts "By reason: #{data[:by_reason].map { |key, count| "#{key}=#{count}" }.join(", ")}"
      puts "Applied countries (top 15):"
      data[:applied_countries].each { |name, count| puts "  #{name}: #{count}" }
      puts "Disagreements (#{data[:disagreements].size}):"
      data[:disagreements].each do |d|
        puts "  ##{d[:book_id]} #{d[:title]}: #{d[:held].join(", ")} -> #{d[:proposed]} (enrichment #{d[:enrichment_id]})"
      end
      puts "Unmatched answers (top 20):"
      data[:no_match].each { |raw, count| puts "  #{raw}: #{count}" }
      puts "Research rows: #{data[:research_rows]} (about $#{format("%.2f", data[:research_cost_estimate])})"
      puts "Deferred research: #{data[:deferred_research]}"
    end

    desc "List disagreements (a well-supported answer against the held country); APPLY=1 replaces the held country. " \
      "IDS=1,2 narrows to those enrichment ids: bin/rails \"books:origin:accept_disagreements[origin-v1]\""
    task :accept_disagreements, [:label] => :environment do |_task, args|
      ids = ENV["IDS"].to_s.split(",").map(&:strip).reject(&:empty?).map { Integer(it) }.presence
      apply = ENV["APPLY"] == "1"
      data = ::Services::Books::Origin::AcceptDisagreements.call(label: args[:label].presence, enrichment_ids: ids, apply: apply).data
      data[:candidates].each do |d|
        puts "##{d[:book_id]} #{d[:title]}: #{d[:held].join(", ")} -> #{d[:proposed]} (enrichment #{d[:enrichment_id]})"
      end
      if apply
        puts "accepted #{data[:accepted]}"
      else
        puts "#{data[:candidates].size} candidates. Re-run with APPLY=1 to accept them."
      end
    end
  end
end
