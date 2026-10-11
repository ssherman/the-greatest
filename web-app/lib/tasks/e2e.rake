# Marker on every row e2e:import_finder_seed/e2e:import_finder_cleanup own. The
# spec finds its rows by id (printed by the seed) and the cleanup finds them
# by this marker.
IMPORT_FINDER_MARKER = "E2E import finder audit seed"

# The placeholder author e2e:reject_link_seed owns, found by name. The QID is
# the Wikidata sandbox item, so a stray row names nobody real.
REJECT_LINK_AUTHOR = "E2E Reject Link Seed"
REJECT_LINK_QID = "Q4115189"
REJECT_LINK_URL = "https://en.wikipedia.org/wiki/Wikipedia:Sandbox"

# The provisional book and author e2e:provisional_seed owns, found by title and name.
PROVISIONAL_BOOK_TITLE = "E2E Provisional Seed"
PROVISIONAL_AUTHOR_NAME = "E2E Provisional Seed Author"

# The seed edition, book and author e2e:goodreads_import_seed owns. The id is
# far above any real Goodreads id in the dev data.
GOODREADS_SEED_ID = 999_000_001
GOODREADS_SEED_TITLE = "E2E Goodreads Import Seed"
GOODREADS_SEED_AUTHOR = "E2E Goodreads Import Author"
# The filename of e2e/fixtures/goodreads_export.csv, as the upload stores it.
E2E_GOODREADS_FIXTURE = "goodreads_export.csv"

namespace :e2e do
  # One value from e2e/.env. Read from the file rather than ENV because these
  # tasks run from a shell that has not loaded that file, and dotenv only loads
  # web-app/.env.
  def playwright_env(key)
    env_file = Rails.root.join("e2e", ".env")
    abort "Missing #{env_file}. Copy e2e/.env.example and fill it in." unless File.exist?(env_file)

    value = File.readlines(env_file)
      .grep(/\A#{key}=/)
      .first
      &.split("=", 2)
      &.last
      &.strip
      &.delete_prefix('"')
      &.delete_suffix('"')

    abort "#{key} not set in #{env_file}" if value.blank?
    value
  end

  def playwright_email = playwright_env("PLAYWRIGHT_ADMIN_EMAIL")

  # The seed project runs these tasks from Playwright, whose config loads
  # e2e/.env into the process env, so the value is normally already there.
  # The file fallback keeps `bin/rails e2e:prepare` usable from a bare shell.
  def playwright_email_for(key)
    ENV[key].presence || playwright_env(key)
  end

  desc "Rebuild everything the Playwright suite needs from the three e2e accounts (roles, membership, reviews, lists, Stripe plans, rate limiter, manifest). Idempotent; the `seed` project runs it on every yarn test:e2e"
  task prepare: :environment do
    result = Services::E2e::Prepare.call(
      emails: {
        admin: playwright_email_for("PLAYWRIGHT_ADMIN_EMAIL"),
        user: playwright_email_for("PLAYWRIGHT_USER_EMAIL"),
        member: playwright_email_for("PLAYWRIGHT_MEMBER_EMAIL")
      },
      manifest_path: Rails.root.join("e2e", ".auth", "seed.json"),
      log: ->(line) { puts line }
    )
    abort result.errors.join("\n") unless result.success?
  end

  desc "Clear the per-IP rate limiter; e2e/tests/books/contact.spec.ts runs this before its tests so a rerun within the hour passes"
  task rate_limit_reset: :environment do
    Rails.application.config.x.rate_limit_store.clear
    puts "rate limiter cleared"
  end

  desc "Seed one match decision and one duplicate pair for e2e/tests/books/admin/import-finder-audit.spec.ts (E2E_BOOK_A, E2E_BOOK_B override the slugs)"
  task import_finder_seed: :environment do
    # Exactly what the spec drives: one needs-review decision (unmatched, with
    # the created record set and one local candidate, so the show page offers
    # "Merge into candidate 1") and one pending pair between the same two
    # books. Idempotent: a second run resets the rows the spec reviewed and
    # dismissed instead of adding more. Prints one JSON line with the ids.
    book_a = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_A", "headlong-hall"))
    book_b = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_B", "war-and-peace"))
    a, b = [book_a.id, book_b.id].minmax

    pair = DuplicateCandidate.find_or_initialize_by(item_type: "Books::Book", item_a_id: a, item_b_id: b)
    if pair.persisted? && pair.evidence.to_h["reason"] != IMPORT_FINDER_MARKER
      abort "A real duplicate_candidates row already exists for #{book_a.slug} + #{book_b.slug} (##{pair.id}); " \
        "pick other books with E2E_BOOK_A / E2E_BOOK_B."
    end

    decision = MatchDecision.find_or_initialize_by(finder: "DataImporters::Books::Book::Finder", reason: IMPORT_FINDER_MARKER)
    candidate = DataImporters::Candidate.new(
      record: book_b, sources: [:opensearch], scores: {opensearch: 7.5},
      evidence: {title: book_b.title, creators: book_b.authors.map(&:name), year: book_b.first_published_year}
    )
    decision.assign_attributes(
      record: book_a, subject: nil, outcome: :unmatched, confidence: :low, decided_by: :ai, verify: false,
      query: {"title" => book_a.title, "author_names" => book_a.authors.map(&:name), "year" => book_a.first_published_year},
      candidates: [candidate.snapshot], selected_index: nil, sources_failed: [],
      needs_review: true, reviewed_at: nil, reviewed_by: nil, review_note: nil, created_at: Time.current
    )
    decision.save!

    pair.assign_attributes(
      source: :bulk_verify, status: :pending, evidence: {"reason" => IMPORT_FINDER_MARKER}, occurrences: 1,
      match_decision: decision, resolved_at: nil, resolved_by: nil, resolution_note: nil, created_at: Time.current
    )
    pair.save!

    puts({decision_id: decision.id, pair_id: pair.id}.to_json)
  end

  desc "Remove the rows e2e:import_finder_seed created"
  task import_finder_cleanup: :environment do
    pairs = DuplicateCandidate.where("evidence->>'reason' = ?", IMPORT_FINDER_MARKER).to_a
    decisions = MatchDecision.where(reason: IMPORT_FINDER_MARKER).to_a
    pairs.each(&:destroy!)
    decisions.each(&:destroy!)
    puts "removed #{pairs.size} pair(s) and #{decisions.size} decision(s)"
  end

  desc "Seed one proposed relink verdict for e2e/tests/books/admin/repair-verdicts.spec.ts (E2E_BOOK_A, E2E_BOOK_B override the slugs)"
  task repair_verdicts_seed: :environment do
    # A verdict names records by id only; rejecting it (what the spec does)
    # changes no catalog data, and approving would not either until an apply
    # run. Idempotent: resets the one e2e verdict.
    from = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_A", "headlong-hall"))
    to = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_B", "war-and-peace"))
    verdict = Books::RepairVerdict.find_or_initialize_by(kind: :relink, subject_key: "e2e:relink")
    verdict.update!(status: :proposed, decided_by: :ai, confidence: :high, reason: "E2E repair verdicts spec",
      decided_by_user_id: nil, reviewed_at: nil, applied_at: nil, error: nil,
      payload: {user_id: 0, from_book_id: from.id, to_book_id: to.id, goodreads_book_id: 0, rows: []})
    puts({verdict_id: verdict.id}.to_json)
  end

  desc "Remove the verdict e2e:repair_verdicts_seed created"
  task repair_verdicts_cleanup: :environment do
    puts "removed #{Books::RepairVerdict.where("subject_key LIKE 'e2e:%'").delete_all} verdict(s)"
  end

  desc "Seed a placeholder author with one matched Wikidata link for e2e/tests/books/admin/reject-link.spec.ts"
  task reject_link_seed: :environment do
    # A placeholder (exclude_from_rankings), so the Wikidata run the reject
    # queues skips it without calling Wikidata, VIAF or a model. Idempotent:
    # a rerun resets the author's link rows and its decision.
    author = Books::Author.find_or_initialize_by(name: REJECT_LINK_AUTHOR)
    author.update!(exclude_from_rankings: true, birth_year: 1901)
    author.identifiers.each(&:destroy!)
    author.external_links.each(&:destroy!)
    author.enrichments.each(&:destroy!)
    MatchDecision.where(subject: author).each(&:destroy!)

    author.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: REJECT_LINK_QID)
    author.external_links.create!(url: REJECT_LINK_URL, name: "Wikipedia", source: :wikipedia, link_category: :information)
    decision = MatchDecision.create!(
      finder: "Services::Books::Authors::ResolveWikidata", subject: author, record: nil, outcome: :matched,
      confidence: :medium, decided_by: :ai, verify: false, needs_review: true, reason: "E2E reject link seed",
      query: {"name" => author.name},
      candidates: [{"record_type" => nil, "record_id" => nil, "external_source" => "wikidata", "external_key" => REJECT_LINK_QID,
                    "sources" => ["name_search"], "scores" => {}, "evidence" => {"external_title" => "Wikidata Sandbox"}}],
      selected_index: 1
    )
    author.enrichments.create!(
      kind: "books.author_wikidata", provider: "wikidata", outcome: :applied, reason: "matched #{REJECT_LINK_QID}",
      recognized: true, match_decision: decision, facts: {
        "wikidata_qid" => {"value" => REJECT_LINK_QID, "applied" => true, "reason" => "filled"},
        "birth_year" => {"value" => 1901, "applied" => true, "reason" => "filled"},
        "wikipedia" => {"value" => REJECT_LINK_URL, "applied" => true, "reason" => "linked"}
      }
    )

    puts({decision_id: decision.id, author_id: author.id}.to_json)
  end

  desc "Print the e2e:reject_link_seed author's link state as JSON"
  task reject_link_state: :environment do
    author = Books::Author.find_by!(name: REJECT_LINK_AUTHOR)
    puts({
      wikidata_qids: author.identifiers.where(identifier_type: :books_author_wikidata_qid).pluck(:value),
      birth_year: author.birth_year,
      links: author.external_links.pluck(:url)
    }.to_json)
  end

  desc "Remove the author e2e:reject_link_seed created, with its decisions"
  task reject_link_cleanup: :environment do
    author = Books::Author.find_by(name: REJECT_LINK_AUTHOR)
    decisions = author ? MatchDecision.where(subject: author).to_a : []
    decisions.each(&:destroy!)
    author&.destroy!
    puts "removed #{author ? 1 : 0} author and #{decisions.size} decision(s)"
  end

  desc "Seed a provisional book and author for e2e/tests/books/provisional.spec.ts"
  task provisional_seed: :environment do
    # Idempotent: a rerun finds both rows and re-flags them.
    author = Books::Author.find_or_initialize_by(name: PROVISIONAL_AUTHOR_NAME)
    author.update!(provisional: true, exclude_from_rankings: true)
    book = Books::Book.find_or_initialize_by(title: PROVISIONAL_BOOK_TITLE)
    book.update!(provisional: true)
    Books::BookAuthor.find_or_create_by!(book: book, author: author) { |credit| credit.role = :author }

    puts({book_slug: book.slug, author_slug: author.slug}.to_json)
  end

  desc "Remove the rows e2e:provisional_seed created"
  task provisional_cleanup: :environment do
    book = Books::Book.find_by(title: PROVISIONAL_BOOK_TITLE)
    author = Books::Author.find_by(name: PROVISIONAL_AUTHOR_NAME)
    book&.destroy!
    author&.destroy!
    puts "removed #{[book, author].compact.size} row(s)"
  end

  desc "Remove the lists e2e/tests/books/admin/list-wizard.spec.ts created (name prefix only)"
  task list_wizard_cleanup: :environment do
    removed = 0
    Books::List.where("name LIKE ?", "E2E Wizard List %").find_each do |list|
      list.destroy!
      removed += 1
    end
    puts "removed #{removed} list(s)"
  end

  desc "Seed a finished Goodreads import with one provisional book for the Playwright admin " \
    "(E2E_GOODREADS_EMAIL overrides the account). Idempotent."
  task goodreads_import_seed: :environment do
    user = User.find_by!(email: ENV.fetch("E2E_GOODREADS_EMAIL") { playwright_email })
    author = Books::Author.find_or_create_by!(name: GOODREADS_SEED_AUTHOR) { |a| a.provisional = true }
    book = Books::Book.find_by(title: GOODREADS_SEED_TITLE) || Books::Book.create!(title: GOODREADS_SEED_TITLE, provisional: true)
    Books::BookAuthor.find_or_create_by!(book: book, author: author) { |book_author| book_author.position = 1 }
    signature = Books::Goodreads::ExportRow.signature(GOODREADS_SEED_TITLE, GOODREADS_SEED_AUTHOR)
    edition = Books::GoodreadsEdition.find_or_create_by!(goodreads_book_id: GOODREADS_SEED_ID, signature: signature) do |e|
      e.assign_attributes(title: GOODREADS_SEED_TITLE, primary_author: GOODREADS_SEED_AUTHOR)
    end
    edition.update!(book: book, resolution: :created, verification: :verified, resolved_at: edition.resolved_at || Time.current)
    import = Books::GoodreadsImport.joins(:rows).where(user: user, status: :complete, review_status: :pending)
      .find_by(books_goodreads_import_rows: {goodreads_edition_id: edition.id})
    import ||= user.goodreads_imports.create!(status: :complete, rows_count: 1, editions_count: 1, created_count: 1,
      started_at: Time.current, finished_at: Time.current).tap do |created|
      created.rows.create!(row_number: 1, goodreads_edition: edition, outcome: :applied, exclusive_shelf: "to-read",
        raw: {"Book Id" => GOODREADS_SEED_ID.to_s, "Title" => GOODREADS_SEED_TITLE, "Author" => GOODREADS_SEED_AUTHOR})
      [book, author].each { |record| created.records.create!(record: record, action: :created) }
    end
    puts({import_id: import.id, book_id: book.id}.to_json)
  end

  desc "Remove what e2e:goodreads_import_seed and the Goodreads import E2E upload created"
  task goodreads_import_cleanup: :environment do
    edition_ids = Books::GoodreadsEdition.where(goodreads_book_id: GOODREADS_SEED_ID).pluck(:id)
    named = Books::GoodreadsImport.where(id: Books::GoodreadsImportRow.where(goodreads_edition_id: edition_ids).select(:import_id))
    # An upload no worker parsed has no rows yet; it is found by the
    # fixture's filename on the Playwright account.
    user = User.find_by(email: ENV.fetch("E2E_GOODREADS_EMAIL") { playwright_email })
    unparsed = user ? user.goodreads_imports.joins(file_attachment: :blob)
      .where(active_storage_blobs: {filename: E2E_GOODREADS_FIXTURE}) : Books::GoodreadsImport.none
    Books::GoodreadsImport.where(id: named.select(:id)).or(Books::GoodreadsImport.where(id: unparsed.select(:id))).find_each do |import|
      # A worker may have run the upload: take back what it wrote first.
      if import.member? && !import.review_rejected? && !import.in_progress?
        Services::Books::GoodreadsImports::Revert.call(import: import, reviewer: import.user)
      end
      import.file.purge if import.file.attached?
      import.destroy!
    end
    Books::GoodreadsEdition.where(id: edition_ids).find_each(&:destroy!)
    Books::Book.where(title: GOODREADS_SEED_TITLE).find_each(&:destroy!)
    Books::Author.where(name: GOODREADS_SEED_AUTHOR).find_each(&:destroy!)
    puts "cleaned up the Goodreads import E2E records"
  end
end
