namespace :e2e do
  def playwright_email
    env_file = Rails.root.join("e2e", ".env")
    abort "Missing #{env_file}. Copy e2e/.env.example and fill it in." unless File.exist?(env_file)

    email = File.readlines(env_file)
      .grep(/\APLAYWRIGHT_ADMIN_EMAIL=/)
      .first
      &.split("=", 2)
      &.last
      &.strip
      &.delete_prefix('"')
      &.delete_suffix('"')

    abort "PLAYWRIGHT_ADMIN_EMAIL not set in #{env_file}" if email.blank?
    email
  end

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
end
