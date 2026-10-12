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
    force = ENV["FORCE"] == "1"
    describe = lambda do |data|
      next data.inspect if data[:skipped]

      names = ::Category.where(id: data[:kept] + data[:removed]).pluck(:id, :name).to_h
      label = ->(ids) { ids.map { |id| names[id] || id }.join(", ") }
      "kept [#{label.call(data[:kept])}] removed [#{label.call(data[:removed])}] -- #{data[:reason]}#{" (dry run)" if data[:dry_run]}"
    end
    ::Services::Books::TrimLocations.candidate_ids(limit: limit, force: force).each do |book_id|
      book = ::Books::Book.find(book_id)
      result = ::Services::Books::TrimLocations.call(book: book, dry_run: dry_run, force: force)
      status = result.success? ? describe.call(result.data) : "FAILED #{result.errors.join("; ")}"
      puts "#{book.title} (##{book.id}): #{status}"
    end
  end
end
