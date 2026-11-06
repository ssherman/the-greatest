namespace :workflows do
  desc "List workflow steps that need attention: failed, or overdue by more than HOURS (default 6)"
  task :stuck, [:hours] => :environment do |_task, args|
    hours = (args[:hours].presence || 6).to_f
    rows = Workflows::Stuck.call(older_than: hours.hours)

    if rows.empty?
      puts "No stuck workflow steps."
    else
      rows.each do |row|
        puts [
          "run ##{row[:run_id]}", row[:workflow], row[:target], row[:step], row[:state],
          "since #{row[:since]&.utc&.iso8601 || "?"}", row[:error].to_s.squish.truncate(160).presence
        ].compact.join("  ")
      end
      puts "#{rows.size} stuck step#{"s" unless rows.size == 1}."
    end
  end
end

namespace :books do
  namespace :workflows do
    desc "One-off after the book workflow deploys: plan a book_facts run for every book still deferred to its " \
      "authors, waiting on any active author run; the limit is optional. Safe to re-run: bin/rails books:workflows:adopt_deferred[500]"
    task :adopt_deferred, [:limit] => :environment do |_task, args|
      limit = args[:limit].presence&.to_i
      abort "Usage: bin/rails books:workflows:adopt_deferred[limit] -- the limit is optional, but a positive number" if limit && !limit.positive?

      counts = ::Workflows::Books::AdoptDeferred.call(limit: limit)
      puts "Planned #{counts[:planned]} book run(s); left #{counts[:skipped_active]} book(s) that already have a running book run."
    end
  end
end
