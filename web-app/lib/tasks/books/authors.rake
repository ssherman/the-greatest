namespace :books do
  namespace :authors do
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
      puts "Queued #{data[:wikidata]} author(s) for the Wikidata step, one every #{spacing}s; " \
        "the last starts about #{data[:wikidata_done_at].utc.iso8601}."
      puts "Queued #{data[:viaf]} author(s) to retry the VIAF step." if data[:viaf].positive?
      puts "Left out #{data[:left_out]} author(s) with a chain job already waiting in Sidekiq." if data[:left_out].positive?
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
