namespace :books do
  desc "Enrich one book with AI now: bin/rails books:enrich[123] or [some-slug]"
  task :enrich, [:book_id] => :environment do |_task, args|
    # Rake args are always strings, and Books::Book uses friendly_id with :finders --
    # so a bare .find("13") resolves by SLUG, and 137 books have purely numeric slugs
    # that shadow real ids. Decide explicitly instead of letting friendly_id guess.
    identifier = args[:book_id].to_s
    abort "Usage: bin/rails books:enrich[id-or-slug]" if identifier.blank?
    book = if identifier.match?(/\A\d+\z/)
      ::Books::Book.find_by!(id: identifier)
    else
      ::Books::Book.friendly.find(identifier)
    end

    puts "Enriching #{book.title} (##{book.id})..."
    result = ::Services::Books::EnrichBook.call(book: book)
    result.data[:enrichments].each do |row|
      puts "  #{row.mode}: #{row.outcome}#{" (#{row.reason})" if row.reason}#{" -- #{row.error}" if row.error}"
      row.facts.each do |name, entry|
        puts "    #{name}: #{entry["reason"]}#{" -> #{entry["value"].inspect}" if entry["applied"]}"
      end
    end
    abort "Enrichment failed: #{result.errors.join("; ")}" unless result.success?
  end

  desc "Enqueue enrichment for books with no ledger row and no description: bin/rails books:enrich_missing[100]"
  task :enrich_missing, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails books:enrich_missing[limit] -- a limit is required; running wide is a decision" unless limit.positive?

    scope = ::Books::Book
      .where.not(id: Enrichment.where(enrichable_type: "Books::Book").select(:enrichable_id))
      .where.not(id: Description.where(describable_type: "Books::Book").select(:describable_id))
      .order(:id)
      .limit(limit)

    # pluck keeps the order; find_each would drop it and batch by primary key.
    ids = scope.pluck(:id)
    ids.each { |id| Books::EnrichBookJob.perform_async(id) }
    puts "Enqueued #{ids.size} book(s) for enrichment."
  end
end
