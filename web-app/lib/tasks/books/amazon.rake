namespace :books do
  desc "Backfill edition-level ASIN/ISBN/EAN identifiers from legacy Amazon metadata (one-time)"
  task backfill_edition_asins: :environment do
    puts "Backfilling edition identifiers from legacy Amazon metadata..."
    written = Services::Books::EditionIdentifierBackfill.call
    puts "Done. #{written} identifier rows attempted (duplicates ignored)."
  end

  desc "Enrich one book from Amazon: bin/rails books:amazon_enrich[123] or [some-slug]"
  task :amazon_enrich, [:book_id] => :environment do |_task, args|
    # Rake args are always strings, and Books::Book uses friendly_id with :finders --
    # so a bare .find("13") resolves by SLUG, and 137 books have purely numeric slugs
    # that shadow real ids. Decide explicitly instead of letting friendly_id guess.
    identifier = args[:book_id].to_s
    book = if identifier.match?(/\A\d+\z/)
      ::Books::Book.find_by!(id: identifier)
    else
      ::Books::Book.friendly.find(identifier)
    end

    puts "Enriching #{book.title} (##{book.id})..."
    Books::AmazonProductEnrichmentJob.new.perform(book.id)
    puts "Done."
  end

  desc "Enqueue Amazon enrichment for every ranked book, best-ranked first"
  task amazon_enrich_ranked: :environment do
    configuration = ::Books::RankingConfiguration.default_primary
    abort "No default primary books ranking configuration" if configuration.nil?

    scope = ::Books::Book
      .joins(:ranked_items)
      .where(ranked_items: {ranking_configuration_id: configuration.id})
      .where("books_books.amazon_enriched_at IS NULL OR books_books.amazon_enriched_at < ?", 7.days.ago)
      .order("ranked_items.rank ASC")

    total = scope.count
    puts "Enqueuing #{total} ranked books onto the :serial queue."
    puts "At one job at a time this takes days, and it shares that queue with the"
    puts "cover-art and recording-id jobs. Ctrl-C now if that is not what you want."

    # find_each ignores the `order` clause above and batches by primary key, so
    # rank ordering is NOT preserved through it -- `order` only governs
    # `scope.count` and manual inspection here. If strict rank ordering matters
    # for a given run, replace find_each with scope.limit(N).pluck(:id).each,
    # run it in chunks, and note that in the run log.
    enqueued = 0
    scope.find_each(order: :desc) do |book|
      Books::AmazonProductEnrichmentJob.perform_async(book.id)
      enqueued += 1
      puts "... #{enqueued}/#{total}" if (enqueued % 500).zero?
    end

    puts "Enqueued #{enqueued} books."
  end
end
