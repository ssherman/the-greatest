namespace :books do
  namespace :authors do
    desc "Merge every placeholder author (Anonymous, Unknown Author, ...) into the canonical Unknown author. " \
      "Dry run by default; APPLY=1 queues the merge on Sidekiq: bin/rails books:authors:merge_unknown APPLY=1"
    task merge_unknown: :environment do
      result = ::Services::Books::Authors::MergeUnknown.call(apply: false)
      abort "books:authors:merge_unknown: #{result.errors.join("; ")}" unless result.success?

      data = result.data
      puts "Target: author #{data[:target_id]} \"#{::Services::Books::Authors::UnknownAuthor::CANONICAL_NAME}\" (#{data[:target_books]} books)."
      if data[:sources].empty?
        puts "Nothing to merge."
        next
      end

      puts "Would merge #{data[:sources].size} author(s), #{data[:sources].sum { |source| source[:books] }} book link(s):"
      data[:sources].each { |source| puts "  #{source[:name]} (id #{source[:id]}, #{source[:books]} books)" }
      if ENV["APPLY"] == "1"
        Books::MergeUnknownAuthorsJob.perform_async
        puts "Queued Books::MergeUnknownAuthorsJob. Progress: the worker log."
      else
        puts "Dry run. Re-run with APPLY=1 to queue the merge."
      end
    end

    desc "Queue the author chain (Wikidata, VIAF on a miss, then AI with research off) for authors the Wikidata step " \
      "has not processed, ranked authors first: bin/rails \"books:authors:enrich[100]\" or [all]"
    task :enrich, [:limit] => :environment do |_task, args|
      raw = args[:limit].to_s.strip
      limit = (raw == "all") ? nil : Integer(raw, exception: false)
      unless raw == "all" || limit&.positive?
        abort "Usage: bin/rails \"books:authors:enrich[limit]\" -- a number, or all. A limit is required: a wide run is a decision."
      end

      started = Time.current
      data = ::Services::Books::Authors::Backfill.call(limit: limit).data
      spacing = ::Services::Books::Authors::Backfill::SPACING
      puts "Planned #{data[:wikidata]} author run(s) starting at the Wikidata step, one every #{spacing}s; " \
        "the last starts about #{data[:wikidata_done_at].utc.iso8601}."
      puts "Planned #{data[:viaf]} author run(s) starting at the VIAF step to retry it." if data[:viaf].positive?
      puts "Left out #{data[:left_out]} author(s) that already have an active run or a chain job waiting in Sidekiq." if data[:left_out].positive?
      puts "Wikidata misses go on to VIAF at about two requests a minute; each author's AI step follows its last record step."
      puts "Report: bin/rails \"books:authors:enrich_report[#{started.utc.iso8601}]\""
    end

    desc "Report what the author steps did since a time, before a wider backfill: " \
      "bin/rails \"books:authors:enrich_report[2026-10-02T12:00:00Z]\""
    task :enrich_report, [:since] => :environment do |_task, args|
      since = begin
        Time.iso8601(args[:since].to_s)
      rescue ArgumentError
        nil
      end
      abort "Usage: bin/rails \"books:authors:enrich_report[ISO-8601 time]\" -- the time the batch was queued" if since.nil?

      puts ::Services::Books::Authors::BackfillReport.call(since: since).data[:lines]
    end
  end
end
