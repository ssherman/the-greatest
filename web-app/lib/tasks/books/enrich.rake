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

  desc "Enqueue enrichment for books with no ledger row and no description, plus any book still waiting on its new authors' chain (a description does not exempt those): bin/rails books:enrich_missing[100]"
  task :enrich_missing, [:limit] => :environment do |_task, args|
    limit = args[:limit].to_i
    abort "Usage: bin/rails books:enrich_missing[limit] -- a limit is required; running wide is a decision" unless limit.positive?

    # A book whose only rows defer to its new authors (spec §10) is still
    # missing: its author chain may never have reached it. The reason test
    # is NULL-safe on purpose -- where.not(reason:) would also drop every row
    # with no reason, which is most applied runs, and queue those books again.
    ledgered = Enrichment.where(enrichable_type: "Books::Book")
      .where("enrichments.reason IS DISTINCT FROM ?", ::Services::Books::DeferredEnrichment::REASON)
    # The no-description rule only protects a book that was never deferred:
    # the Open Library provider can write a description onto a brand-new book
    # before AiEnrichment defers it to its new authors, so a deferred book
    # counts as missing whatever descriptions it already has.
    missing = ::Books::Book.where.not(id: ledgered.select(:enrichable_id))
    waiting = Enrichment.where(enrichable_type: "Books::Book", reason: ::Services::Books::DeferredEnrichment::REASON).select(:enrichable_id)
    described = Description.where(describable_type: "Books::Book").select(:describable_id)
    scope = missing.where.not(id: described).or(missing.where(id: waiting))
      .order(:id)
      .limit(limit)

    # pluck keeps the order; find_each would drop it and batch by primary key.
    ids = scope.pluck(:id)
    ids.each { |id| Books::EnrichBookJob.perform_async(id) }
    puts "Enqueued #{ids.size} book(s) for enrichment."
  end
end
