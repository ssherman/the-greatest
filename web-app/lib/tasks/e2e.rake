# Marker on every row e2e:import_finder_seed/e2e:import_finder_cleanup own. The
# spec finds its rows by id (printed by the seed) and the cleanup finds them
# by this marker.
IMPORT_FINDER_MARKER = "E2E import finder audit seed"

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
    # states of their own (nightmare-abbey: zero reviews; the-great-gatsby and
    # room-for-murder: specific migrated review corpora).
    excluded_slugs = %w[nightmare-abbey the-great-gatsby room-for-murder]
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
    book_a = Books::Book.find_by!(slug: ENV.fetch("E2E_BOOK_A", "nightmare-abbey"))
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
      needs_review: true, reviewed_at: nil, reviewed_by: nil, review_note: nil
    )
    decision.save!

    pair.assign_attributes(
      source: :bulk_verify, status: :pending, evidence: {"reason" => IMPORT_FINDER_MARKER}, occurrences: 1,
      match_decision: decision, resolved_at: nil, resolved_by: nil, resolution_note: nil
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
end
