namespace :books do
  # The upserter matches editions by their edition-level identifiers. The backfill
  # commits batch by batch, so an interrupted run leaves some editions covered and
  # the rest not -- and the uncovered ones get silently DUPLICATED. Checking that
  # one identifier exists is not enough; verify that none are missing.
  #
  # Editions already enriched are correctly excluded: enrichment overwrites
  # metadata["amazon"] with the lowerCamelCase blob, so the PascalCase "ASIN" key
  # is gone and the row drops out of this scope -- by which point the upserter has
  # already written its identifier.
  def assert_edition_identifiers_backfilled!(editions_relation, description)
    missing = editions_relation
      .where("books_editions.metadata -> 'amazon' ->> 'ASIN' IS NOT NULL")
      .where.not(
        id: Identifier
          .where(identifiable_type: "Books::Edition", identifier_type: :books_edition_asin)
          .select(:identifiable_id)
      )
      .count

    return if missing.zero?

    abort "#{missing} #{description} still carry legacy Amazon metadata with no " \
      "books_edition_asin identifier. Run books:backfill_edition_asins to completion " \
      "first -- enriching now would create a duplicate edition for each of them."
  end

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

    assert_edition_identifiers_backfilled!(book.editions, "editions of this book")

    puts "Enriching #{book.title} (##{book.id})..."
    Books::AmazonProductEnrichmentJob.new.perform(book.id)
    puts "Done."
  end

  desc "Enqueue Amazon enrichment for every ranked book, best-ranked first"
  task amazon_enrich_ranked: :environment do
    assert_edition_identifiers_backfilled!(::Books::Edition.all, "editions")

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

    # find_each ignores the scope's order and batches by primary key, so it cannot
    # preserve rank. 24,242 ids is a trivial pluck and keeps the ordering the
    # operator was promised.
    enqueued = 0
    scope.pluck(:id).each do |book_id|
      Books::AmazonProductEnrichmentJob.perform_async(book_id)
      enqueued += 1
      puts "... #{enqueued}/#{total}" if (enqueued % 500).zero?
    end

    puts "Enqueued #{enqueued} books."
  end
end
