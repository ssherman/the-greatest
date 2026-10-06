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

  desc "Grant the Playwright admin account (e2e/.env PLAYWRIGHT_ADMIN_EMAIL) the global admin role"
  task admin: :environment do
    email = playwright_email
    user = User.find_by(email: email)

    if user.nil?
      abort <<~MSG
        No User with email #{email}.

        The account must exist in Firebase AND in this database. Sign in once through
        the browser as that account to create the Rails User record, then re-run this task.
      MSG
    end

    user.update!(role: :admin)
    puts "#{email} (id #{user.id}) is now a global admin."
  end

  desc "Grant the Playwright member account (e2e/.env PLAYWRIGHT_MEMBER_EMAIL) a comped membership"
  task member: :environment do
    email = playwright_env("PLAYWRIGHT_MEMBER_EMAIL")
    user = User.find_by(email: email)

    if user.nil?
      abort <<~MSG
        No User with email #{email}.

        The account must exist in Firebase AND in this database. Sign in once through
        the browser as that account to create the Rails User record, then re-run this task.
      MSG
    end

    # find_or_initialize_by on (user, source): the index on those two columns
    # makes this idempotent, so re-running after a dev-database refresh is safe.
    # A comp with no end date grants access until someone deactivates it.
    membership = user.memberships.find_or_initialize_by(source: :comped)
    membership.assign_attributes(status: :active, current_period_end: nil, note: "Playwright member account (bin/rails e2e:member)")
    membership.save!

    puts "#{email} (id #{user.id}) is a comped member."
  end

  desc "Ensure the Playwright account owns one public and one private books list, each with items"
  task books_public_list: :environment do
    email = playwright_email
    user = User.find_by(email: email)
    abort "No User with email #{email}. Run `bin/rails e2e:admin` first." if user.nil?

    books = Books::Book.where(book_kind: :standalone).limit(3).to_a
    abort "No standalone books in this database." if books.empty?

    public_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Public Books") do |list|
      list.list_type = :custom
    end
    public_list.update!(public: true)
    books.each { |book| public_list.user_list_items.find_or_create_by!(listable: book) }

    private_list = Books::UserList.find_or_create_by!(user: user, name: "E2E Private Books") do |list|
      list.list_type = :custom
    end
    private_list.update!(public: false)
    books.first(1).each { |book| private_list.user_list_items.find_or_create_by!(listable: book) }

    puts "PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID=#{public_list.id}"
    puts "PLAYWRIGHT_PRIVATE_BOOKS_LIST_ID=#{private_list.id}"
  end

  desc "Ensure the Playwright account has 30 Books::Book reviews (6 per rating) for e2e/tests/books/account/my-reviews.spec.ts"
  task my_reviews: :environment do
    email = playwright_email
    user = User.find_by(email: email)
    abort "No User with email #{email}. Run `bin/rails e2e:admin` first." if user.nil?

    # Excluded because other specs depend on these three having specific review
    # states of their own (headlong-hall: zero reviews; the-great-gatsby and
    # room-for-murder: specific migrated review corpora).
    excluded_slugs = %w[headlong-hall the-great-gatsby room-for-murder]
    target_count = 30

    # The spec searches its own reviews for "Animal Farm" and asserts exactly one
    # hit, so that review has to exist. Seeding by ascending id happens to pick
    # this book first on a fresh account, but that is an emergent property of the
    # ordering, not a guarantee -- on an account that already held other reviews
    # it would not hold. Ensure it directly instead, before the bulk seed, so the
    # count arithmetic below accounts for it.
    #
    # Four other books match "%animal farm%" (ids 81938, 114995, 115161, 126072).
    # All are far above the ids the bulk seed reaches, so the search still finds
    # exactly one -- but if this task ever stops ordering by id, that assertion
    # is the first thing that breaks.
    anchor = Books::Book.find_by(slug: "animal-farm")
    abort "No Books::Book with slug 'animal-farm'; the spec's search test needs it." if anchor.nil?
    user.reviews.find_or_create_by!(reviewable: anchor) do |review|
      review.rating = 5
      review.body = "Seed review for the E2E /my/reviews search test."
    end

    scope = user.reviews.where(reviewable_type: "Books::Book")
    already_reviewed_ids = scope.pluck(:reviewable_id)
    needed = target_count - already_reviewed_ids.size

    # Additive only, by design: the development database is not disposable (the
    # books corpus exists nowhere else and takes hours to rebuild), so this task
    # will not delete reviews to reach the target. That means an account already
    # at or over the target cannot be reconciled here -- say so loudly rather
    # than exiting 0 and letting the spec fail later with an assertion mismatch
    # that looks like a product bug.
    if needed.negative?
      warn "WARNING: #{email} has #{already_reviewed_ids.size} Books::Book reviews, " \
           "more than the target #{target_count}. This task will not delete reviews. " \
           "e2e/tests/books/account/my-reviews.spec.ts asserts an exact count and will " \
           "fail until the extras are removed by hand."
    end

    if needed.positive?
      books = Books::Book.where.not(slug: excluded_slugs)
        .where.not(id: already_reviewed_ids)
        .order(:id)
        .limit(needed)
      abort "Not enough Books::Book rows available to seed #{needed} more reviews." if books.size < needed

      # Rating cycles 1..5 so the finished set always has exactly 6 reviews per
      # rating -- e2e/tests/books/account/my-reviews.spec.ts's rating-bar-filter
      # test depends on every rating having at least one row, and this keeps the
      # split even. `n` continues from however many already exist so a resumed
      # (previously interrupted) run still lands on an even split, not just this
      # batch. The "Animal Farm" anchor the search test needs is guaranteed
      # above rather than relying on it being the lowest non-excluded id.
      books.each_with_index do |book, i|
        n = already_reviewed_ids.size + i
        rating = (n % 5) + 1
        body = n.odd? ? "Seed review #{n} for E2E /my/reviews spec (task 11)." : nil
        user.reviews.find_or_create_by!(reviewable: book) do |review|
          review.rating = rating
          review.body = body
        end
      end
    end

    total = scope.count
    puts "#{email} (id #{user.id}) has #{total} Books::Book reviews (target #{target_count})."
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
