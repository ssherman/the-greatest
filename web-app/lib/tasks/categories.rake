namespace :categories do
  desc "Add missing inherited location links and remove orphaned ones, for every book (idempotent)"
  task reconcile_ancestors: :environment do
    result = ::Categories::AncestorReconciler.call
    puts "Inherited location links: #{result.data[:added]} added, #{result.data[:removed]} removed"
  end

  desc "Trim books with too many direct locations (one AI call per book): bin/rails 'categories:trim_locations[100]' (DRY_RUN=1 prints, FORCE=1 re-trims)"
  task :trim_locations, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails 'categories:trim_locations[LIMIT]' -- a limit is required" unless limit.positive?

    dry_run = ENV["DRY_RUN"] == "1"
    ::Services::Books::TrimLocations.candidate_ids(limit: limit).each do |book_id|
      book = ::Books::Book.find(book_id)
      result = ::Services::Books::TrimLocations.call(book: book, dry_run: dry_run, force: ENV["FORCE"] == "1")
      status = result.success? ? result.data.inspect : "FAILED #{result.errors.join("; ")}"
      puts "#{book.title} (##{book.id}): #{status}"
    end
  end
end
