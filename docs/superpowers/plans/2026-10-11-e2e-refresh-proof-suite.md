# E2E Refresh-Proof Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `yarn test:e2e` fully green after a production-dump refresh with zero manual steps, driving three distinct accounts (admin, normal user, paid member).

**Architecture:** Five Playwright sign-in setup projects create the accounts' `User` rows through the real login modal; a `seed` project then runs one idempotent `bin/rails e2e:prepare` (backed by `Services::E2e::Prepare`) that sets roles and memberships, resets the accounts' own seed data, syncs Stripe plans, clears the rate limiter, verifies famous slugs and writes a manifest that specs read instead of `.env`. Two small app fixes remove the failures that production data and a client-side race expose.

**Tech Stack:** Rails 8 (Minitest 6, Mocha, ViewComponent), Playwright 1.64 (TypeScript), Stimulus, Stripe sandbox.

**Spec:** `docs/superpowers/specs/2026-10-10-e2e-refresh-proof-suite-design.md`

## Global Constraints

- Work happens in the worktree `/home/shane/dev/the-greatest/.claude/worktrees/e2e-refresh-proof-suite` on branch `worktree-e2e-refresh-proof-suite`. Never commit to `main`. Never push or open a PR without asking.
- Run Rails and yarn commands from `web-app/` inside that worktree. Absolute path: `/home/shane/dev/the-greatest/.claude/worktrees/e2e-refresh-proof-suite/web-app`.
- Services live in `app/lib/services/<domain>/` and return `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`. Tests mirror the path under `test/lib/services/`.
- Minitest is 6.x: `assert_nil`, never `assert_equal nil, x`. Stub every external call with Mocha. Never test private methods.
- Lint with `bundle exec standardrb` (not `bin/rubocop`). A clean `bin/rails test` emits no new warnings.
- Rails 8 enum syntax (`enum :status, {...}`); `find_or_initialize_by`, never `build`, for anything re-run.
- DaisyUI 5 / Tailwind 4: never use `form-control`, `label-text`, `input-bordered`, `select-bordered` (the lint test `test/lint/daisyui_v4_classes_test.rb` fails on them).
- Playwright: `data-testid` only when role/text/label cannot target an element; kebab-case. Music project is named `chromium`; do not rename it.
- The dev database is not disposable. The only deletions this plan performs are of rows owned by the three e2e accounts, through the service, or of the e2e accounts themselves inside a snapshot-protected rehearsal (Task 7).
- Port 3000 must belong to this worktree before any E2E run. Check:
  `pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"`
  If it prints another checkout, stop and tell Shane.
- Never run `bin/dev` (needs a TTY). Start the app with `yarn build:all` then `bin/rails server -p 3000`, plus `bundle exec sidekiq -C config/sidekiq.yml`.
- Firebase accounts are never created by code. The three exist already; their credentials are in `web-app/e2e/.env` (six `PLAYWRIGHT_*` lines, already copied into the worktree).
- CI is out of scope. Do not add workflow files.

## Review Focus

Failure modes the spec implies but no spec section tests directly. Each has a test pinned to the task that owns the code.

1. **An e2e email resolves to a real customer's row** (a typo in `.env` that matches a production user). Expected: prepare refuses and changes nothing. Pinned: Task 1, "refuses an account that holds a Stripe membership and changes nothing".
2. **Two of the three emails are the same** (copy-paste in `.env`). Expected: refuse before touching any row. Pinned: Task 1, "refuses duplicate emails".
3. **Email case differs between Firebase and the row** (`Shane.Sherman+e2e-normal@…`). Expected: still resolves. Pinned: Task 1, "matches emails case-insensitively".
4. **Fresh clone, no `e2e/.auth/` directory yet.** Expected: the manifest write creates it. Pinned: Task 1, "creates the manifest directory".
5. **Fewer books than the review target** (a trimmed database). Expected: one clear error, not a half-seeded account. Pinned: Task 1, "fails with a clear error when there are not enough books".

---

### Task 1: `Services::E2e::Prepare` — accounts, roles, memberships, owned seed data

**Files:**
- Create: `web-app/app/lib/services/e2e/prepare.rb`
- Test: `web-app/test/lib/services/e2e/prepare_test.rb`

**Interfaces:**
- Produces: `Services::E2e::Prepare.call(emails:, manifest_path:, review_target: 30, anchor_slug: "animal-farm", required_slugs: REQUIRED_SLUGS, sync_plans: Services::Billing::SyncPlans, rate_limit_store: Rails.application.config.x.rate_limit_store, log: ->(line) {})` returning `Result` with `data` = the manifest hash `{generated_at:, users: {admin: {id:, email:}, user: {...}, member: {...}}, lists: {public_books:, private_books:}, verified_slugs:}` on success, `errors` (array of strings) on failure. `emails` is `{admin:, user:, member:}`.
- Task 2 wires this into `bin/rails e2e:prepare`. Task 3's manifest helper reads the JSON this writes.

Context the implementer needs:
- Sign-in matches a `User` by `auth_uid`, and a password account's email is untrusted, so prepare must never create rows; it only finds rows a browser sign-in already created. Lookup mirrors `Services::UserAuthenticationService#find_user`: `User.person.where("LOWER(email) = ?", email.downcase).order(:id).first`.
- `Membership` enums: `source` `{stripe: 0, comped: 1, legacy: 2}` with `prefix: true` (so `memberships.source_stripe` is a scope), `status` includes `active` and `canceled`. `Membership.granting_access` is the scope behind `User#member?`. A comped active membership with `current_period_end: nil` grants access forever.
- `Review`: `belongs_to :reviewable, polymorphic: true`, `rating` 1..5 or nil, `rating_or_body_present` validation, `user_id` unique per reviewable.
- `Books::UserList`: `list_type` enum includes `custom`; `public` boolean; `user_list_items` with `before_validation :set_position`. `Books::Book.book_kind` enum has `standalone`.
- `Services::Billing::SyncPlans.call` returns its own `Result` with `data[:resolved]` (array of lookup keys) and `errors`.
- Fixtures: `books_books(:war_and_peace)` exists; there are only 7 book fixtures, so tests pass `review_target: 5` and `anchor_slug: "war-and-peace"`. `categories(:books_fiction_genre)` has slug `fiction`. `users(:regular_user)` holds a Stripe membership (`memberships(:regular_user_monthly)`). `User.create!(email: ...)` works and auto-creates ~17 default lists (fine; they are not named "E2E …").
- In test, `Rails.application.config.x.rate_limit_store` is a `MemoryStore`; pass a fresh `ActiveSupport::Cache::MemoryStore.new`.

- [ ] **Step 1: Write the failing tests**

Create `web-app/test/lib/services/e2e/prepare_test.rb`:

```ruby
require "test_helper"

module Services
  module E2e
    class PrepareTest < ActiveSupport::TestCase
      SYNC_OK = ::Services::Billing::SyncPlans::Result.new(success?: true, data: {resolved: %w[membership_monthly]}, errors: [])
      SYNC_FAILED = ::Services::Billing::SyncPlans::Result.new(success?: false, data: {resolved: [], failures: ["membership_monthly"], invalid: []}, errors: ["membership_monthly: no active price"])

      setup do
        @admin = User.create!(email: "e2e-admin@example.com")
        @user = User.create!(email: "e2e-user@example.com")
        @member = User.create!(email: "e2e-member@example.com")
        @bystander = User.create!(email: "bystander@example.com")
        @manifest_path = Rails.root.join("tmp", "e2e-prepare-test-#{Process.pid}", "nested", "seed.json")
        @store = ActiveSupport::Cache::MemoryStore.new
      end

      teardown do
        FileUtils.rm_rf(@manifest_path.dirname.dirname)
      end

      def emails(admin: @admin.email, user: @user.email, member: @member.email)
        {admin: admin, user: user, member: member}
      end

      def prepare(sync: stub(call: SYNC_OK), **overrides)
        Prepare.call(**{
          emails: emails,
          manifest_path: @manifest_path,
          review_target: 5,
          anchor_slug: "war-and-peace",
          required_slugs: {books: %w[war-and-peace], books_categories: %w[fiction], games_categories: []},
          sync_plans: sync,
          rate_limit_store: @store
        }.merge(overrides))
      end

      test "promotes the admin, strips the user's comp, comps the member, and all three stay non-admin except the admin" do
        @user.memberships.create!(source: :comped, status: :active, current_period_end: nil, note: "stray comp")
        @member.update!(role: :editor)

        result = prepare
        assert result.success?, result.errors.inspect

        assert_equal "admin", @admin.reload.role
        assert_equal "user", @user.reload.role
        assert_equal "user", @member.reload.role
        assert_not @admin.member?
        assert_not @user.member?
        assert @member.member?
        assert_equal 1, @member.memberships.source_comped.count
      end

      test "is idempotent: a second run leaves exactly one comp and the same review and list counts" do
        prepare
        first = [@member.memberships.count, @user.reviews.count, Books::UserList.where(user: @user, name: [Prepare::PUBLIC_LIST_NAME, Prepare::PRIVATE_LIST_NAME]).count]
        prepare
        second = [@member.memberships.count, @user.reviews.count, Books::UserList.where(user: @user, name: [Prepare::PUBLIC_LIST_NAME, Prepare::PRIVATE_LIST_NAME]).count]
        assert_equal first, second
        assert_equal [1, 5, 2], second
      end

      test "resets the user's book reviews to the exact target, with every rating present and the anchor reviewed" do
        stray = books_books(:crime_and_punishment)
        @user.reviews.create!(reviewable: stray, rating: 2, body: "stray")

        result = prepare
        assert result.success?, result.errors.inspect

        reviews = @user.reviews.where(reviewable_type: "Books::Book")
        assert_equal 5, reviews.count
        assert_equal [1, 2, 3, 4, 5], reviews.pluck(:rating).sort
        assert reviews.exists?(reviewable: books_books(:war_and_peace))
      end

      test "touches no other user's reviews or lists" do
        @bystander.reviews.create!(reviewable: books_books(:war_and_peace), rating: 4)
        before = [@bystander.reviews.count, Books::UserList.where(user: @bystander).count]

        prepare

        assert_equal before, [@bystander.reviews.count, Books::UserList.where(user: @bystander).count]
      end

      test "recreates the public and private lists with items and reports their ids" do
        old = Books::UserList.create!(user: @user, name: Prepare::PUBLIC_LIST_NAME, list_type: :custom, public: false)

        result = prepare
        assert result.success?, result.errors.inspect

        public_list = Books::UserList.find(result.data[:lists][:public_books])
        private_list = Books::UserList.find(result.data[:lists][:private_books])
        assert_not Books::UserList.exists?(old.id)
        assert_equal [Prepare::PUBLIC_LIST_NAME, true, 3], [public_list.name, public_list.public, public_list.user_list_items.count]
        assert_equal [Prepare::PRIVATE_LIST_NAME, false, 1], [private_list.name, private_list.public, private_list.user_list_items.count]
        assert_equal @user, public_list.user
      end

      test "writes the manifest and creates its directory" do
        result = prepare
        assert result.success?, result.errors.inspect

        manifest = JSON.parse(File.read(@manifest_path))
        assert_equal @user.id, manifest.dig("users", "user", "id")
        assert_equal @user.email, manifest.dig("users", "user", "email")
        assert_equal result.data[:lists][:public_books], manifest.dig("lists", "public_books")
        assert manifest["generated_at"].present?
      end

      test "clears the rate limiter" do
        @store.write("contact:127.0.0.1", 5)
        prepare
        assert_nil @store.read("contact:127.0.0.1")
      end

      test "refuses a missing account and names it" do
        result = prepare(emails: emails(member: "nobody@example.com"))

        assert_not result.success?
        assert_match(/no User for nobody@example.com/, result.errors.join)
        assert_equal "user", @admin.reload.role
      end

      test "refuses an account that holds a Stripe membership and changes nothing" do
        customer = users(:regular_user)
        result = prepare(emails: emails(member: customer.email))

        assert_not result.success?
        assert_match(/Stripe membership/, result.errors.join)
        assert_equal "user", @admin.reload.role
        assert_equal 0, @user.reviews.count
      end

      test "refuses duplicate emails" do
        result = prepare(emails: emails(member: @user.email))

        assert_not result.success?
        assert_match(/three different emails/, result.errors.join)
        assert_equal "user", @admin.reload.role
      end

      test "matches emails case-insensitively" do
        result = prepare(emails: emails(user: @user.email.upcase))
        assert result.success?, result.errors.inspect
        assert_equal 5, @user.reviews.count
      end

      test "fails when the Stripe sync fails and writes no manifest" do
        result = prepare(sync: stub(call: SYNC_FAILED))

        assert_not result.success?
        assert_match(/stripe: membership_monthly/, result.errors.join)
        assert_not File.exist?(@manifest_path)
      end

      test "fails the catalog preflight listing every missing slug" do
        result = prepare(required_slugs: {books: %w[war-and-peace no-such-book], books_categories: %w[no-such-genre], games_categories: []})

        assert_not result.success?
        assert_match(/Books::Book no-such-book/, result.errors.join)
        assert_match(/Books::Category no-such-genre/, result.errors.join)
        assert_not File.exist?(@manifest_path)
      end

      test "fails with a clear error when there are not enough books" do
        result = prepare(review_target: 500)

        assert_not result.success?
        assert_match(/books available/, result.errors.join)
      end
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd web-app && bin/rails test test/lib/services/e2e/prepare_test.rb`
Expected: every test errors with `NameError: uninitialized constant Services::E2e`.

- [ ] **Step 3: Write the service**

Create `web-app/app/lib/services/e2e/prepare.rb`:

```ruby
module Services
  module E2e
    # Rebuilds everything the Playwright suite needs from the three e2e
    # accounts, idempotently, on every `yarn test:e2e` run: the `seed` project
    # shells out to `bin/rails e2e:prepare`, which calls this. A production
    # dump refresh wipes the accounts' User rows, roles, memberships, reviews
    # and lists; this puts them back from nothing once the browser sign-ins
    # have recreated the rows. Design: docs/superpowers/specs/
    # 2026-10-10-e2e-refresh-proof-suite-design.md
    #
    # It never creates a User (sign-in is the only path that does, and a
    # password account's email is untrusted, so a pre-created row would make
    # sign-in refuse the account). The only rows it deletes are reviews and
    # lists OWNED by the three e2e accounts, which exist for this suite alone.
    # It never touches a table, and it refuses any account that holds a Stripe
    # membership, because that is a real customer, not an e2e account.
    class Prepare
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)
      class SeedError < StandardError; end

      REVIEW_TARGET = 30
      ANCHOR_SLUG = "animal-farm"
      # Other specs need these three to keep a review state of their own
      # (headlong-hall: zero reviews; the other two: migrated corpora).
      EXCLUDED_REVIEW_SLUGS = %w[headlong-hall the-great-gatsby room-for-murder].freeze
      PUBLIC_LIST_NAME = "E2E Public Books"
      PRIVATE_LIST_NAME = "E2E Private Books"
      COMP_NOTE = "Playwright member account (bin/rails e2e:prepare)"
      # The catalog rows specs assume survive a refresh (famous books keep
      # their slugs). Checked last, so a renamed slug fails in one line here
      # instead of in a dozen specs.
      REQUIRED_SLUGS = {
        books: %w[war-and-peace headlong-hall animal-farm the-great-gatsby room-for-murder],
        books_categories: %w[novels],
        games_categories: %w[action]
      }.freeze
      ROLES = {admin: :admin, user: :user, member: :user}.freeze

      def self.call(**) = new(**).call

      def initialize(emails:, manifest_path:, review_target: REVIEW_TARGET, anchor_slug: ANCHOR_SLUG,
        required_slugs: REQUIRED_SLUGS, sync_plans: ::Services::Billing::SyncPlans,
        rate_limit_store: Rails.application.config.x.rate_limit_store, log: ->(_line) {})
        @emails = emails.slice(:admin, :user, :member)
        @manifest_path = Pathname(manifest_path)
        @review_target = review_target
        @anchor_slug = anchor_slug
        @required_slugs = required_slugs
        @sync_plans = sync_plans
        @rate_limit_store = rate_limit_store
        @log = log
      end

      def call
        errors = []
        accounts = resolve_accounts(errors)
        return failure(errors) if errors.any?

        assign_roles(accounts)
        reset_reviews(accounts[:user])
        lists = reset_lists(accounts[:user])
        sync_stripe(errors)
        return failure(errors) if errors.any?

        clear_rate_limiter
        preflight(errors)
        return failure(errors) if errors.any?

        Result.new(success?: true, data: write_manifest(accounts, lists), errors: [])
      rescue SeedError, ActiveRecord::RecordInvalid => e
        failure([e.message])
      end

      private

      attr_reader :emails, :manifest_path, :review_target, :anchor_slug, :required_slugs,
        :sync_plans, :rate_limit_store, :log

      def failure(errors) = Result.new(success?: false, data: nil, errors: errors)

      # Every check here runs before any write, so a bad .env changes nothing.
      def resolve_accounts(errors)
        missing_keys = ROLES.keys - emails.keys
        if missing_keys.any?
          errors << "missing e2e account emails: #{missing_keys.join(", ")}"
          return {}
        end
        if emails.values.map { |e| e.to_s.downcase }.uniq.size != ROLES.size
          errors << "the three e2e accounts must have three different emails (got #{emails.values.join(", ")})"
          return {}
        end

        emails.transform_values do |email|
          user = ::User.person.where("LOWER(email) = ?", email.to_s.downcase).order(:id).first
          if user.nil?
            errors << "no User for #{email}; the seed project signs it in first (a browser sign-in creates the row)"
          elsif user.memberships.source_stripe.exists?
            errors << "#{email} holds a Stripe membership, so it is a real customer, not an e2e account; refusing to touch it"
          end
          user
        end
      end

      def assign_roles(accounts)
        ROLES.each { |key, role| accounts[key].update!(role: role) }

        # The admin and the normal user must never pass a paywall: a comp
        # applied by hand would make tests/books/account/membership.spec.ts
        # vacuous. Canceled with a past period end is outside granting_access
        # for every source.
        [accounts[:admin], accounts[:user]].each do |user|
          user.memberships.granting_access.find_each do |membership|
            membership.update!(status: :canceled, current_period_end: 1.day.ago)
          end
          log.call("#{user.email} (id #{user.id}): role #{user.role}, not a member")
        end

        member = accounts[:member]
        membership = member.memberships.find_or_initialize_by(source: :comped)
        membership.assign_attributes(status: :active, current_period_end: nil, note: COMP_NOTE)
        membership.save!
        log.call("#{member.email} (id #{member.id}): role user, comped member")
      end

      # Exact state, not additive: tests/books/account/my-reviews.spec.ts
      # asserts the total and rotates one rating, so a run that only added
      # reviews would drift. The anchor is the one hit the spec's search for
      # "Animal Farm" expects, and the bulk must not include another title
      # matching it.
      def reset_reviews(user)
        user.reviews.where(reviewable_type: "Books::Book").find_each(&:destroy!)

        anchor = ::Books::Book.find_by(slug: anchor_slug)
        raise SeedError, "no Books::Book with slug #{anchor_slug.inspect}; the /my/reviews search test needs it" if anchor.nil?

        user.reviews.create!(reviewable: anchor, rating: 5, body: "Seed review for the E2E /my/reviews search test.")

        needed = review_target - 1
        books = ::Books::Book.where.not(slug: EXCLUDED_REVIEW_SLUGS).where.not(id: anchor.id).order(:id).limit(needed).to_a
        raise SeedError, "only #{books.size} books available for #{needed} seed reviews" if books.size < needed

        lookalike = books.find { |book| book.title.to_s.match?(/animal farm/i) }
        raise SeedError, "seed book ##{lookalike.id} (#{lookalike.title}) would be a second 'Animal Farm' search hit" if lookalike

        # (i % 5) + 1 after a rating-5 anchor gives six per rating at 30.
        books.each_with_index do |book, i|
          user.reviews.create!(reviewable: book, rating: (i % 5) + 1,
            body: i.odd? ? "Seed review #{i} for the E2E /my/reviews spec." : nil)
        end
        log.call("#{user.email}: #{review_target} Books::Book reviews")
      end

      def reset_lists(user)
        ::Books::UserList.where(user: user, name: [PUBLIC_LIST_NAME, PRIVATE_LIST_NAME]).find_each(&:destroy!)

        books = ::Books::Book.where(book_kind: :standalone).order(:id).limit(3).to_a
        raise SeedError, "only #{books.size} standalone books available; the E2E lists need 3" if books.size < 3

        public_list = ::Books::UserList.create!(user: user, name: PUBLIC_LIST_NAME, list_type: :custom, public: true)
        books.each { |book| public_list.user_list_items.create!(listable: book) }
        private_list = ::Books::UserList.create!(user: user, name: PRIVATE_LIST_NAME, list_type: :custom, public: false)
        private_list.user_list_items.create!(listable: books.first)

        log.call("#{user.email}: lists #{public_list.id} (public, 3 items), #{private_list.id} (private, 1 item)")
        {public_books: public_list.id, private_books: private_list.id}
      end

      # The dump brings production's live Stripe price ids; dev talks to a
      # sandbox. Re-resolving by lookup key is the documented post-refresh
      # step nobody remembered.
      def sync_stripe(errors)
        result = sync_plans.call
        if result.success?
          log.call("stripe: #{result.data[:resolved].size} plan(s) re-resolved")
        else
          errors.concat(result.errors.map { |error| "stripe: #{error}" })
        end
      end

      # Namespaced store: .clear is a scoped delete, never a Redis flush (see
      # config/initializers/rate_limit_store.rb).
      def clear_rate_limiter
        rate_limit_store.clear
        log.call("rate limiter cleared")
      end

      def preflight(errors)
        missing = []
        missing.concat(missing_slugs(::Books::Book, required_slugs.fetch(:books, [])))
        missing.concat(missing_slugs(::Books::Category, required_slugs.fetch(:books_categories, [])))
        missing.concat(missing_slugs(::Games::Category, required_slugs.fetch(:games_categories, [])))
        if missing.any?
          errors << "catalog preflight: missing #{missing.join(", ")}"
        else
          log.call("catalog preflight: #{required_slugs.values.sum(&:size)} slug(s) present")
        end
      end

      def missing_slugs(model, slugs)
        slugs.reject { |slug| model.exists?(slug: slug) }.map { |slug| "#{model.name} #{slug}" }
      end

      def write_manifest(accounts, lists)
        manifest = {
          generated_at: Time.current.iso8601,
          users: accounts.transform_values { |user| {id: user.id, email: user.email} },
          lists: lists,
          verified_slugs: required_slugs
        }
        FileUtils.mkdir_p(manifest_path.dirname)
        File.write(manifest_path, JSON.pretty_generate(manifest))
        log.call("manifest written to #{manifest_path}")
        manifest
      end
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/services/e2e/prepare_test.rb`
Expected: 14 runs, 0 failures, 0 errors. If `User.create!(email:)` fails a validation, read `app/models/user.rb` validations and add the minimum attribute in the test's `setup`; do not weaken the model.

- [ ] **Step 5: Lint and zeitwerk**

Run: `cd web-app && bundle exec standardrb app/lib/services/e2e test/lib/services/e2e && CI=1 bin/rails zeitwerk:check`
Expected: no offenses; "All is good!"

- [ ] **Step 6: Commit**

```bash
git add web-app/app/lib/services/e2e/prepare.rb web-app/test/lib/services/e2e/prepare_test.rb
git commit -m "E2E: Services::E2e::Prepare rebuilds the three e2e accounts' state from nothing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `bin/rails e2e:prepare` and `e2e:rate_limit_reset`; delete the four manual tasks

**Files:**
- Modify: `web-app/lib/tasks/e2e.rake` (the `admin`, `member`, `books_public_list`, `my_reviews` tasks and the `playwright_email` helper are at lines 27–165; the per-spec seed tasks below them stay)
- Test: `web-app/test/lib/tasks/e2e_rake_test.rb`

**Interfaces:**
- Consumes: `Services::E2e::Prepare.call(emails:, manifest_path:, log:)` from Task 1.
- Produces: `bin/rails e2e:prepare` (exit 0 on success, aborts with the errors on failure; reads `PLAYWRIGHT_ADMIN_EMAIL`, `PLAYWRIGHT_USER_EMAIL`, `PLAYWRIGHT_MEMBER_EMAIL` from the process env first, falling back to `e2e/.env`) and `bin/rails e2e:rate_limit_reset`. Task 3's seed project runs the first; Task 4's contact spec runs the second.
- Keep: `playwright_env(key)` and `playwright_email` (the Goodreads seed tasks default to it).

- [ ] **Step 1: Write the failing rake test**

Create `web-app/test/lib/tasks/e2e_rake_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "rake"

class E2eRakeTest < ActiveSupport::TestCase
  PREPARE = Services::E2e::Prepare
  ENV_KEYS = %w[PLAYWRIGHT_ADMIN_EMAIL PLAYWRIGHT_USER_EMAIL PLAYWRIGHT_MEMBER_EMAIL].freeze

  setup do
    # Load only this one rake file (see penalties_rake_test.rb for why not
    # Rails.application.load_tasks).
    unless Rake::Task.task_defined?("e2e:prepare")
      Rake::Task.define_task(:environment) {} unless Rake::Task.task_defined?(:environment)
      silence_warnings { load Rails.root.join("lib/tasks/e2e.rake").to_s }
    end
    @previous = ENV_KEYS.index_with { |key| ENV[key] }
    ENV["PLAYWRIGHT_ADMIN_EMAIL"] = "a@example.com"
    ENV["PLAYWRIGHT_USER_EMAIL"] = "u@example.com"
    ENV["PLAYWRIGHT_MEMBER_EMAIL"] = "m@example.com"
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def invoke(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  test "e2e:prepare hands the three env emails and the manifest path to the service" do
    PREPARE.expects(:call).with(has_entries(
      emails: {admin: "a@example.com", user: "u@example.com", member: "m@example.com"},
      manifest_path: Rails.root.join("e2e", ".auth", "seed.json")
    )).returns(PREPARE::Result.new(success?: true, data: {}, errors: []))

    invoke("e2e:prepare")
  end

  test "e2e:prepare aborts with the service's errors, one per line" do
    PREPARE.stubs(:call).returns(PREPARE::Result.new(success?: false, data: nil, errors: ["no User for a@example.com", "stripe: down"]))

    assert_output(nil, /no User for a@example.com\nstripe: down/) do
      assert_raises(SystemExit) { invoke("e2e:prepare") }
    end
  end

  test "e2e:rate_limit_reset clears the store" do
    store = Rails.application.config.x.rate_limit_store
    store.write("contact:127.0.0.1", 5)

    assert_output(/rate limiter cleared/) { invoke("e2e:rate_limit_reset") }
    assert_nil store.read("contact:127.0.0.1")
  end

  test "the four manual account tasks are gone" do
    %w[e2e:admin e2e:member e2e:my_reviews e2e:books_public_list].each do |name|
      assert_not Rake::Task.task_defined?(name), "#{name} should have been deleted; prepare replaces it"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd web-app && bin/rails test test/lib/tasks/e2e_rake_test.rb`
Expected: the first three fail with `Don't know how to build task 'e2e:prepare'`; the fourth fails because `e2e:admin` is still defined.

- [ ] **Step 3: Edit the rake file**

In `web-app/lib/tasks/e2e.rake`, delete the `admin`, `member`, `books_public_list` and `my_reviews` tasks (everything from `desc "Grant the Playwright admin account` through the end of `my_reviews`, lines 48–165 in the current file). Keep `playwright_env` and `playwright_email`. Directly after `def playwright_email = playwright_env("PLAYWRIGHT_ADMIN_EMAIL")`, add:

```ruby
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd web-app && bin/rails test test/lib/tasks/e2e_rake_test.rb`
Expected: 4 runs, 0 failures.

- [ ] **Step 5: Lint**

Run: `cd web-app && bundle exec standardrb lib/tasks/e2e.rake test/lib/tasks/e2e_rake_test.rb`
Expected: no offenses.

- [ ] **Step 6: Commit**

```bash
git add web-app/lib/tasks/e2e.rake web-app/test/lib/tasks/e2e_rake_test.rb
git commit -m "E2E: bin/rails e2e:prepare and e2e:rate_limit_reset replace the four manual account tasks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Playwright side — shared sign-in, five setups, seed project, manifest helper, config, scripts

**Files:**
- Create: `web-app/e2e/support/sign-in.ts`, `web-app/e2e/support/seed.ts`, `web-app/e2e/auth/seed.setup.ts`, `web-app/e2e/auth/books-user-auth.setup.ts`
- Modify: `web-app/e2e/auth/auth.setup.ts`, `web-app/e2e/auth/games-auth.setup.ts`, `web-app/e2e/auth/books-auth.setup.ts`, `web-app/e2e/auth/books-member-auth.setup.ts`, `web-app/e2e/playwright.config.ts`, `web-app/package.json:21-24`, `web-app/e2e/.env.example`

**Interfaces:**
- Produces for Task 4: `import { seed } from '<relative>/support/seed'` with `seed(): SeedManifest` where `SeedManifest = { generated_at: string; users: Record<'admin'|'user'|'member', { id: number; email: string }>; lists: { public_books: number; private_books: number } }`. Call it **inside** a test or `beforeAll`, never at module top level: Playwright loads every spec file before the setup projects run, so a top-level call would throw on a fresh checkout.
- Produces for Task 6: `signIn(page, credentials)` and `credentials('ADMIN' | 'USER' | 'MEMBER')` from `support/sign-in`.
- Consumes: `bin/rails e2e:prepare` from Task 2.

Cookie facts: Rails' session cookie is `_the_greatest_session` (`Rails.application.config.session_options[:key]`); `tg_uid` is set by `AuthController` on sign-in. The navbar label flips to "Logout" about 100 ms before those cookies exist, and `networkidle` fires before the sign-in POST is even sent, which is the capture race.

- [ ] **Step 1: Create the sign-in helper**

Create `web-app/e2e/support/sign-in.ts`:

```ts
import { expect, type Page } from '@playwright/test';

export type Credentials = { email: string; password: string };
export type Account = 'ADMIN' | 'USER' | 'MEMBER';

export function credentials(account: Account): Credentials {
  const email = process.env[`PLAYWRIGHT_${account}_EMAIL`];
  const password = process.env[`PLAYWRIGHT_${account}_PASSWORD`];
  if (!email || !password) {
    throw new Error(
      `PLAYWRIGHT_${account}_EMAIL and PLAYWRIGHT_${account}_PASSWORD must be set in e2e/.env (see e2e/.env.example)`
    );
  }
  return { email, password };
}

// Drives the login modal, then waits for the one signal that means Rails has
// issued a session: both the tg_uid and _the_greatest_session cookies exist.
// The navbar label reads "Logout" as soon as Firebase resolves client-side,
// ~100ms before Rails answers POST /auth/sign_in, and networkidle fires in the
// quiet window BEFORE that POST is sent. Capturing storage state on either of
// those signals saved a state with no session, which made every admin spec
// fail as "element not found" on the public homepage.
export async function signIn(page: Page, { email, password }: Credentials): Promise<void> {
  await page.goto('/');
  await page.locator('#navbar_login_button').click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(email);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(password);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  await expect
    .poll(
      async () => {
        const names = (await page.context().cookies()).map((cookie) => cookie.name);
        return names.includes('tg_uid') && names.includes('_the_greatest_session');
      },
      { timeout: 15_000, message: 'Rails never issued a session after the Firebase sign-in' }
    )
    .toBe(true);
}

export async function signInAndSave(page: Page, creds: Credentials, authFile: string): Promise<void> {
  await signIn(page, creds);
  await page.context().storageState({ path: authFile });
}
```

- [ ] **Step 2: Create the manifest helper**

Create `web-app/e2e/support/seed.ts`:

```ts
import fs from 'node:fs';
import path from 'node:path';

export type SeedManifest = {
  generated_at: string;
  users: Record<'admin' | 'user' | 'member', { id: number; email: string }>;
  lists: { public_books: number; private_books: number };
};

const MANIFEST = path.join(__dirname, '..', '.auth', 'seed.json');

// Written by `bin/rails e2e:prepare` (the `seed` project). Read it inside a
// test or beforeAll, never at module top level: Playwright loads every spec
// file before any project runs, so a top-level read would throw on a fresh
// checkout before the seed project had a chance to write it.
export function seed(): SeedManifest {
  if (!fs.existsSync(MANIFEST)) {
    throw new Error(
      `${MANIFEST} is missing. The seed project writes it; yarn test:e2e runs that project automatically, ` +
        `and a single-file run still runs it because every project depends on it.`
    );
  }
  return JSON.parse(fs.readFileSync(MANIFEST, 'utf8')) as SeedManifest;
}
```

- [ ] **Step 3: Create the seed project test**

Create `web-app/e2e/auth/seed.setup.ts`:

```ts
import { test as setup } from '@playwright/test';
import { execSync } from 'node:child_process';
import path from 'node:path';

const WEB_APP = path.resolve(__dirname, '..', '..');

// Runs after the five sign-in setups (which create the User rows) and before
// every test project. One Rails boot, ~10s. Prints the task's own log lines
// so a failure says which step refused and why.
setup('prepare the three e2e accounts and their data', async () => {
  setup.setTimeout(180_000);
  try {
    const out = execSync('bin/rails e2e:prepare', {
      cwd: WEB_APP,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    console.log(out);
  } catch (error) {
    const failed = error as { stdout?: string; stderr?: string };
    throw new Error(`bin/rails e2e:prepare failed:\n${failed.stdout ?? ''}\n${failed.stderr ?? ''}`);
  }
});
```

- [ ] **Step 4: Rewrite the four setups and add the fifth**

Replace `web-app/e2e/auth/auth.setup.ts` with:

```ts
import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

setup('sign in the admin on music', async ({ page }) => {
  await signInAndSave(page, credentials('ADMIN'), path.join(__dirname, '..', '.auth', 'user.json'));
});
```

Replace `web-app/e2e/auth/games-auth.setup.ts` with:

```ts
import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

setup('sign in the admin on games', async ({ page }) => {
  await signInAndSave(page, credentials('ADMIN'), path.join(__dirname, '..', '.auth', 'games-user.json'));
});
```

Replace `web-app/e2e/auth/books-auth.setup.ts` with:

```ts
import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

setup('sign in the admin on books', async ({ page }) => {
  await signInAndSave(page, credentials('ADMIN'), path.join(__dirname, '..', '.auth', 'books-user.json'));
});
```

Create `web-app/e2e/auth/books-user-auth.setup.ts`:

```ts
import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

// The normal user: signed in, never an admin, never a member. Drives the
// books-account project. e2e:prepare enforces both "nevers" on every run.
setup('sign in the normal user on books', async ({ page }) => {
  await signInAndSave(page, credentials('USER'), path.join(__dirname, '..', '.auth', 'books-normal-user.json'));
});
```

Replace `web-app/e2e/auth/books-member-auth.setup.ts` with:

```ts
import { test as setup } from '@playwright/test';
import path from 'path';
import { credentials, signInAndSave } from '../support/sign-in';

// The member: a plain user that e2e:prepare comps on every run. Drives the
// books-member project.
setup('sign in the member on books', async ({ page }) => {
  await signInAndSave(page, credentials('MEMBER'), path.join(__dirname, '..', '.auth', 'books-member.json'));
});
```

- [ ] **Step 5: Rewrite the Playwright config**

Replace `web-app/e2e/playwright.config.ts` with:

```ts
import { defineConfig, devices } from '@playwright/test';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(__dirname, '.env') });

const BOOKS = 'https://dev-new.thegreatestbooks.org';
const MUSIC = 'https://dev.thegreatestmusic.org';
const GAMES = 'https://dev.thegreatest.games';

const auth = (file: string) => path.join(__dirname, '.auth', file);
const musicAdmin = auth('user.json');
const gamesAdmin = auth('games-user.json');
const booksAdmin = auth('books-user.json');
const booksUser = auth('books-normal-user.json');
const booksMember = auth('books-member.json');

// Every test project depends on `seed`, and `seed` depends on the five
// sign-ins, so a run always goes: sign in (creates the User rows) ->
// bin/rails e2e:prepare (roles, membership, seed data, manifest) -> tests.
// Playwright runs a project's dependencies even when a single spec file is
// named on the command line, so nothing ever runs against unprepared state.
const SIGN_INS = ['setup', 'games-setup', 'books-setup', 'books-user-setup', 'books-member-setup'];

export default defineConfig({
  testDir: './tests',
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: 'html',
  use: {
    ignoreHTTPSErrors: true,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: { mode: 'retain-on-failure' },
  },
  projects: [
    { name: 'setup', testDir: './auth', testMatch: 'auth.setup.ts', use: { baseURL: MUSIC } },
    { name: 'games-setup', testDir: './auth', testMatch: 'games-auth.setup.ts', use: { baseURL: GAMES } },
    { name: 'books-setup', testDir: './auth', testMatch: 'books-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'books-user-setup', testDir: './auth', testMatch: 'books-user-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'books-member-setup', testDir: './auth', testMatch: 'books-member-auth.setup.ts', use: { baseURL: BOOKS } },
    { name: 'seed', testDir: './auth', testMatch: 'seed.setup.ts', dependencies: SIGN_INS },
    {
      // Music. Not renamed: docs and memory refer to --project=chromium.
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], baseURL: MUSIC, storageState: musicAdmin },
      testMatch: /music\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'games',
      use: { ...devices['Desktop Chrome'], baseURL: GAMES, storageState: gamesAdmin },
      testMatch: /games\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS },
      testMatch: /books\/(?!admin\/)(?!account\/)(?!member\/).*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-admin',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksAdmin },
      testMatch: /books\/admin\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-account',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksUser },
      testMatch: /books\/account\/.*/,
      dependencies: ['seed'],
    },
    {
      name: 'books-member',
      use: { ...devices['Desktop Chrome'], baseURL: BOOKS, storageState: booksMember },
      testMatch: /books\/member\/.*/,
      dependencies: ['seed'],
    },
  ],
});
```

- [ ] **Step 6: Scripts and env example**

In `web-app/package.json`, change the four test scripts (leave `test:e2e:codegen` alone):

```json
    "test:e2e": "npx playwright install chromium && npx playwright test --config=e2e/playwright.config.ts",
    "test:e2e:ui": "npx playwright install chromium && npx playwright test --config=e2e/playwright.config.ts --ui",
    "test:e2e:headed": "npx playwright install chromium && npx playwright test --config=e2e/playwright.config.ts --headed",
    "test:e2e:debug": "npx playwright install chromium && npx playwright test --config=e2e/playwright.config.ts --debug",
```

Replace `web-app/e2e/.env.example` with:

```env
# Three Firebase email/password accounts, created once by hand in the shared
# Firebase project. Everything database-side is rebuilt by `bin/rails
# e2e:prepare` on every run. Quote a password that contains `#`.
PLAYWRIGHT_ADMIN_EMAIL=your-admin-test-account@example.com
PLAYWRIGHT_ADMIN_PASSWORD="your-password-here"
PLAYWRIGHT_USER_EMAIL=your-normal-user-test-account@example.com
PLAYWRIGHT_USER_PASSWORD="your-password-here"
PLAYWRIGHT_MEMBER_EMAIL=your-member-test-account@example.com
PLAYWRIGHT_MEMBER_PASSWORD="your-password-here"
```

- [ ] **Step 7: Type-check and run only the setup chain**

Run: `cd web-app && npx tsc --noEmit -p e2e/tsconfig.json`
Expected: no errors.

Confirm port 3000 is yours (Global Constraints), then start the app from this worktree:

```bash
cd web-app && yarn build:all
(bin/rails server -p 3000 > log/e2e-server.log 2>&1 &)
(bundle exec sidekiq -C config/sidekiq.yml > log/e2e-sidekiq.log 2>&1 &)
curl -sk -o /dev/null -w "%{http_code}\n" https://dev-new.thegreatestbooks.org/   # 200
```

Run: `npx playwright test --config=e2e/playwright.config.ts --project=seed --reporter=list`
Expected: 6 passed (five sign-ins, then seed), with the prepare log lines printed (roles, 30 reviews, two list ids, stripe, rate limiter, preflight, manifest). `e2e/.auth/seed.json` exists.

- [ ] **Step 8: Commit**

```bash
git add web-app/e2e/support web-app/e2e/auth web-app/e2e/playwright.config.ts web-app/package.json web-app/e2e/.env.example
git commit -m "E2E: shared sign-in on real cookies, five setups, seed project runs e2e:prepare before every test

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Spec migrations and locator repairs

**Files:**
- Modify: `web-app/e2e/tests/books/account/my-lists.spec.ts`, `web-app/e2e/tests/books/public-list.spec.ts`, `web-app/e2e/tests/books/account/goodreads-import.spec.ts:9-10`, `web-app/e2e/tests/books/account/membership.spec.ts:6-10`, `web-app/e2e/tests/books/account/developers.spec.ts:3`, `web-app/e2e/tests/books/contact.spec.ts`, `web-app/e2e/tests/books/account/my-reviews.spec.ts:106`, `web-app/e2e/tests/books/account/reading-goals.spec.ts:154`

**Interfaces:**
- Consumes: `seed()` from Task 3; `bin/rails e2e:rate_limit_reset` from Task 2; `process.env.PLAYWRIGHT_USER_EMAIL` (loaded by the config's dotenv call).

- [ ] **Step 1: List ids from the manifest**

In `web-app/e2e/tests/books/account/my-lists.spec.ts`: add `import { seed } from '../../../support/seed';` after the Playwright import; delete the line `const publicListId = process.env.PLAYWRIGHT_PUBLIC_BOOKS_LIST_ID!;`; in the "item links" describe, read the id inside each generated test:

```ts
    test(`a book title in ${label} view navigates to the book page`, async ({ page }) => {
      const publicListId = seed().lists.public_books;
      await page.goto(`/my/lists/${publicListId}?view_mode=${viewMode}`);
```

Fix the two navigation expectations (desktop and drawer) to the links the page renders now:

```ts
    await expect(myBooks.getByRole('link')).toHaveText([
      'Lists',
      'Reading Goals',
      'Import from Goodreads',
      'My Rankings',
      'Reviews',
      'Saved Searches',
    ]);
```

In `web-app/e2e/tests/books/public-list.spec.ts`: add `import { seed } from '../../support/seed';`, replace the two `process.env` constants with:

```ts
let publicId: number;
let privateId: number;

// The lists belong to the normal-user e2e account; this project only views
// them, which is why `books` depends on `seed` too.
test.beforeAll(() => {
  ({ public_books: publicId, private_books: privateId } = seed().lists);
});
```

- [ ] **Step 2: Goodreads seed under the user account**

In `web-app/e2e/tests/books/account/goodreads-import.spec.ts` replace the `rails` helper:

```ts
// The books-account project runs as the normal user, so the seed and cleanup
// must own their rows under that account, not the admin the tasks default to.
const rails = (task: string) =>
  execSync(`bin/rails ${task}`, {
    cwd: WEB_APP,
    encoding: "utf8",
    env: { ...process.env, E2E_GOODREADS_EMAIL: process.env.PLAYWRIGHT_USER_EMAIL },
  });
```

- [ ] **Step 3: Comments that named the old arrangement**

In `web-app/e2e/tests/books/account/membership.spec.ts` replace lines 6–10 with:

```ts
// Deliberately NOT covered here: the members'-area view for an actual member.
// That lives in tests/books/member/. This project runs as the normal-user
// e2e account, and `bin/rails e2e:prepare` cancels any membership that account
// holds on every run, so these tests cannot go vacuous by someone comping it.
```

In `web-app/e2e/tests/books/account/developers.spec.ts` line 3, change `PLAYWRIGHT_ADMIN_EMAIL` to `PLAYWRIGHT_USER_EMAIL`.

- [ ] **Step 4: Contact spec owns its rate-limit reset**

In `web-app/e2e/tests/books/contact.spec.ts` add after the Playwright import:

```ts
import { execSync } from 'node:child_process';
import path from 'node:path';

const WEB_APP = path.resolve(__dirname, '..', '..', '..');
```

and as the first line inside `test.describe('Contact form', () => {`:

```ts
  // ContactMessagesController allows 5 anonymous sends per IP per hour and this
  // file sends about 4, so a rerun within the hour fails with confirmation
  // panels that never appear. e2e:prepare clears the limiter for a full run;
  // this covers running the file on its own.
  test.beforeAll(() => {
    execSync('bin/rails e2e:rate_limit_reset', { cwd: WEB_APP, encoding: 'utf8' });
  });
```

- [ ] **Step 5: Locator repairs**

`web-app/e2e/tests/books/account/my-reviews.spec.ts` line 106: the navbar now has its own Search button, so scope to the reviews form:

```ts
    await page.locator('form[action="/my/reviews"]').getByRole('button', { name: 'Search' }).click();
```

`web-app/e2e/tests/books/account/reading-goals.spec.ts` line 154: the add-to-list modal on the same page has a "Make this list public" checkbox that `getByLabel('Public')` also matches:

```ts
    await expect(page.getByRole('checkbox', { name: 'Public', exact: true })).not.toBeChecked();
```

- [ ] **Step 6: Run the affected projects**

Run: `cd web-app && npx tsc --noEmit -p e2e/tsconfig.json`
Expected: no errors.

Run (server from Task 3 still up): `npx playwright test --config=e2e/playwright.config.ts --project=books-account --project=books --reporter=list`
Expected: all pass except the four `categories.spec.ts` tests are not in these projects, and `membership.spec.ts` Stripe tests now pass because prepare synced the plans. Any remaining failure in this run is a defect to fix before committing, not to defer.

- [ ] **Step 7: Commit**

```bash
git add web-app/e2e/tests
git commit -m "E2E: account specs run as the normal user, ids come from the seed manifest, locator rot fixed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Category parent chooser becomes a typeahead

**Files:**
- Modify: `web-app/app/controllers/admin/categories_base_controller.rb` (`domain_config` at line 93; abstract hooks follow), `web-app/app/controllers/admin/books/categories_controller.rb`, `web-app/app/controllers/admin/games/categories_controller.rb`, `web-app/app/controllers/admin/music/categories_controller.rb`, `web-app/app/components/admin/categories/form_component.rb`, `web-app/app/components/admin/categories/form_component.html.erb:58-70`, `web-app/app/models/category.rb`, `web-app/e2e/tests/books/admin/categories.spec.ts`
- Test: `web-app/test/components/admin/categories/form_component_test.rb` (new), the existing category model test (find it with `ls web-app/test/models/category_test.rb`; add the one test below inside its class)

**Interfaces:**
- `domain_config[:categories_search_path]` (string) is new; each controller supplies it via `def categories_search_path`. Route helpers: books `search_admin_books_categories_path`, games `search_admin_games_categories_path`, music `search_admin_categories_path`. The search action (`categories_base_controller.rb:58`) returns `[{value: id, text: name_with_type}]` from an ILIKE query, so a category created a moment ago is found.
- `AutocompleteComponent.new(name:, url:, placeholder:, value:, selected_text:, id:)` renders a hidden input named `name` plus a search box; its Stimulus controller fills the hidden input on selection and clears it when the text is emptied.

Why: `Admin::Categories::FormComponent#parent_categories` renders every category of the domain as an option. Books has 83,425, the New Category page takes over a second to render, and the create flow then never navigates, so four E2E tests time out. Games has 62 and passes.

- [ ] **Step 1: Write the failing component test**

Create `web-app/test/components/admin/categories/form_component_test.rb`:

```ruby
require "test_helper"

class Admin::Categories::FormComponentTest < ViewComponent::TestCase
  include Rails.application.routes.url_helpers

  def books_config
    {
      model_class: Books::Category,
      category_path_proc: ->(category) { admin_books_category_path(category) },
      categories_path: admin_books_categories_path,
      new_category_path: new_admin_books_category_path,
      edit_category_path_proc: ->(category) { edit_admin_books_category_path(category) },
      categories_search_path: search_admin_books_categories_path,
      domain_label: "Books",
      subtitle: "Manage book genres"
    }
  end

  def music_config
    {
      model_class: Music::Category,
      category_path_proc: ->(category) { admin_category_path(category) },
      categories_path: admin_categories_path,
      new_category_path: new_admin_category_path,
      edit_category_path_proc: ->(category) { edit_admin_category_path(category) },
      categories_search_path: search_admin_categories_path,
      domain_label: "Music",
      subtitle: "Manage music genres"
    }
  end

  test "the parent chooser is a typeahead against the domain's category search, never a select of every category" do
    render_inline(Admin::Categories::FormComponent.new(category: Books::Category.new, domain_config: books_config))

    assert_no_selector "select[name='books_category[parent_id]']"
    assert_selector "input[type=hidden][name='books_category[parent_id]']"
    assert_selector "[data-controller=autocomplete][data-autocomplete-url-value='#{search_admin_books_categories_path}']"
  end

  test "editing a child preselects its parent by id and shows the parent's name" do
    child = categories(:music_progressive_rock_genre)
    parent = categories(:music_rock_genre)
    render_inline(Admin::Categories::FormComponent.new(category: child, domain_config: music_config))

    assert_selector "input[type=hidden][name='music_category[parent_id]'][value='#{parent.id}']"
    assert_selector "input[type=search][value='#{parent.name_with_type}']"
  end

  test "a top-level category renders an empty parent" do
    render_inline(Admin::Categories::FormComponent.new(category: categories(:music_rock_genre), domain_config: music_config))

    assert_selector "input[type=hidden][name='music_category[parent_id]']:not([value]), input[type=hidden][name='music_category[parent_id]'][value='']"
    assert_selector "input[type=search]:not([value]), input[type=search][value='']"
  end
end
```

Add to the existing category model test class (`web-app/test/models/category_test.rb`):

```ruby
  test "a category cannot be its own parent" do
    category = categories(:music_rock_genre)
    category.parent = category

    assert_not category.valid?
    assert_includes category.errors[:parent_id], "can't be the category itself"
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd web-app && bin/rails test test/components/admin/categories/form_component_test.rb test/models/category_test.rb`
Expected: the three component tests fail on the `select` still being present / `categories_search_path` missing from the config fetch; the model test fails because the record is valid.

- [ ] **Step 3: Controllers**

In `web-app/app/controllers/admin/categories_base_controller.rb`, add `categories_search_path: categories_search_path,` to the `domain_config` hash (after `categories_path:`), and add the abstract hook next to the others:

```ruby
  def categories_search_path
    raise NotImplementedError, "Subclass must implement categories_search_path"
  end
```

In each subclass add one line next to `categories_path`:

- books: `def categories_search_path = search_admin_books_categories_path`
- games: `def categories_search_path = search_admin_games_categories_path`
- music: `def categories_search_path = search_admin_categories_path`

- [ ] **Step 4: Component**

In `web-app/app/components/admin/categories/form_component.rb` replace `parent_categories` with:

```ruby
  # A typeahead, not a <select>: books has 83k categories and a select of all
  # of them made the admin form unusable on production data.
  def parent_search_url
    domain_config.fetch(:categories_search_path)
  end

  def parent_selected_text
    category.parent&.name_with_type
  end
```

In `web-app/app/components/admin/categories/form_component.html.erb` replace the Parent Category block (the `f.select :parent_id ... %>` call and its helper label) with:

```erb
        <!-- Parent Category -->
        <div>
          <%= f.label :parent_id, class: "label" do %>
            <span class="font-semibold">Parent Category</span>
          <% end %>
          <%= render AutocompleteComponent.new(
                name: "#{f.object_name}[parent_id]",
                id: "#{f.object_name}_parent_id",
                url: parent_search_url,
                value: category.parent_id,
                selected_text: parent_selected_text,
                placeholder: "Search for a parent category..."
              ) %>
          <label class="label">
            <span>Optional: pick a parent to make this a subcategory. Leave empty for a top-level category.</span>
          </label>
        </div>
```

- [ ] **Step 5: Model guard**

In `web-app/app/models/category.rb`, next to the other validations:

```ruby
  validate :parent_is_not_self

  ...

  def parent_is_not_self
    errors.add(:parent_id, "can't be the category itself") if persisted? && parent_id == id
  end
```

(Put `parent_is_not_self` under `private` with the model's other validation methods.)

- [ ] **Step 6: Run the Rails tests**

Run: `cd web-app && bin/rails test test/components/admin/categories test/models/category_test.rb test/controllers/admin`
Expected: all pass. If a controller test asserted the old `<select>`, update it to the hidden input.

- [ ] **Step 7: E2E coverage for the typeahead**

Append to the describe block in `web-app/e2e/tests/books/admin/categories.spec.ts`:

```ts
  test("chooses a parent through the typeahead and the show page links it", async ({ page }) => {
    const parent = `E2E Parent Genre ${Date.now()}`;
    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(parent);
    await page.getByRole("button", { name: "Create Category" }).click();
    await expect(page.getByRole("heading", { name: parent, level: 1 })).toBeVisible();

    const child = `E2E Child Genre ${Date.now()}`;
    await page.goto("/admin/categories/new");
    await page.locator('input[name="books_category[name]"]').fill(child);
    await page.getByPlaceholder("Search for a parent category...").fill(parent);
    await page.locator("li.cursor-pointer", { hasText: parent }).first().click();
    await expect(page.locator('input[name="books_category[parent_id]"]')).not.toHaveValue("");
    await page.getByRole("button", { name: "Create Category" }).click();

    await expect(page.getByRole("heading", { name: child, level: 1 })).toBeVisible();
    await expect(page.getByRole("link", { name: parent })).toBeVisible();
  });
```

Run: `cd web-app && yarn build:all && npx playwright test --config=e2e/playwright.config.ts tests/books/admin/categories.spec.ts --reporter=list` (restart the Rails server first if it was started before this task's Ruby changes; `bin/rails server` does not reload controllers' route helpers reliably: `pkill -f "rails server" ; (bin/rails server -p 3000 > log/e2e-server.log 2>&1 &)`)
Expected: 6 passed, including the four that timed out at baseline.

- [ ] **Step 8: Lint and commit**

Run: `cd web-app && bundle exec standardrb app/controllers/admin app/components/admin/categories app/models/category.rb test/components/admin/categories test/models/category_test.rb && bin/rails test test/lint`
Expected: no offenses; lint tests green.

```bash
git add web-app/app/controllers/admin web-app/app/components/admin/categories web-app/app/models/category.rb web-app/test/components/admin/categories web-app/test/models/category_test.rb web-app/e2e/tests/books/admin/categories.spec.ts
git commit -m "Admin categories: parent chooser is a typeahead, not a select of every category

Books has 83k categories; the select made the New Category form unusable on production data and four E2E tests timed out on it.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `data-auth-state` on the navbar button; login and logout specs wait for it

**Files:**
- Modify: `web-app/app/javascript/controllers/authentication_controller.js:219-231` (`updateNavbarButton`), `web-app/e2e/tests/music/auth/logout.spec.ts`, `web-app/e2e/tests/music/auth/login.spec.ts`

**Interfaces:**
- Consumes: `signIn(page, credentials('ADMIN'))` from Task 3.
- Produces: `#navbar_login_button[data-auth-state="signed-in"|"signed-out"]`, set only by `updateNavbarButton`, i.e. only once Firebase has resolved and the click handler is wired. The server-rendered button and the hint script never set it, so its absence means "not wired yet".

Why: the server renders `<button id="navbar_login_button" onclick="login_modal.showModal()">`. The hint script paints "Logout" immediately on a page that looks signed in, but the click stays `showModal()` until Firebase resolves and `updateNavbarButton` rewires it. The logout spec clicked on the label and opened the login modal.

- [ ] **Step 1: The signal**

In `updateNavbarButton` add one line to each branch, with the comment:

```js
  // Update navbar button based on auth state. data-auth-state is written here
  // and nowhere else, so it says "Firebase has resolved and the click is
  // wired". The label alone does not: the hint script paints "Logout" before
  // that, while the inline onclick still opens the login modal. E2E waits on
  // the attribute.
  updateNavbarButton(user) {
    const navbarButton = document.getElementById('navbar_login_button')
    if (navbarButton) {
      if (user) {
        navbarButton.textContent = 'Logout'
        navbarButton.onclick = () => this.signOut()
        navbarButton.className = 'btn btn-outline btn-error'
        navbarButton.dataset.authState = 'signed-in'
      } else {
        navbarButton.textContent = 'Login'
        navbarButton.onclick = () => this.openModal()
        navbarButton.className = 'btn btn-primary'
        navbarButton.dataset.authState = 'signed-out'
      }
    }
  }
```

- [ ] **Step 2: Logout spec**

Replace `web-app/e2e/tests/music/auth/logout.spec.ts` with:

```ts
import { test, expect } from '@playwright/test';
import { credentials, signIn } from '../../../support/sign-in';

// Fresh login per test: storageState does not capture Firebase's IndexedDB.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Logout Flow', () => {
  test('can log out via navbar button', async ({ page }) => {
    await signIn(page, credentials('ADMIN'));

    // Sign-in reloads the page once Rails has a session. Reloading again here
    // collapses that race into a known fresh page, on which the button is
    // wired only when data-auth-state appears. Clicking on the "Logout" label
    // alone used to open the login modal: the hint paints the label before
    // Firebase rewires the inline onclick.
    await page.reload();
    const button = page.locator('#navbar_login_button');
    await expect(button).toHaveAttribute('data-auth-state', 'signed-in', { timeout: 15_000 });
    await expect(button).toHaveText('Logout');

    await button.click();

    await expect(button).toHaveAttribute('data-auth-state', 'signed-out', { timeout: 10_000 });
    await expect(button).toHaveText('Login');
  });
});
```

- [ ] **Step 3: Login spec**

In `web-app/e2e/tests/music/auth/login.spec.ts`, keep the three tests but replace the body of `'can log in via Firebase email/password'` from the `// Open the auth modal` comment to the end of that test with:

```ts
    await signIn(page, credentials('ADMIN'));
    await expect(loginButton).toHaveAttribute('data-auth-state', 'signed-in', { timeout: 15_000 });
    await expect(loginButton).toHaveText('Logout');
```

and add `import { credentials, signIn } from '../../../support/sign-in';` after the Playwright import. The "starts logged out" assertion at the top of that test stays.

- [ ] **Step 4: Run**

Run: `cd web-app && yarn build:all && npx playwright test --config=e2e/playwright.config.ts tests/music/auth --reporter=list`
Expected: 4 passed.

Negative check (do not commit this): temporarily delete the two `dataset.authState` lines, rebuild, rerun. Expected: the logout test fails on the attribute wait. Restore the lines and rebuild.

- [ ] **Step 5: Commit**

```bash
git add web-app/app/javascript/controllers/authentication_controller.js web-app/e2e/tests/music/auth
git commit -m "Auth: navbar button carries data-auth-state once Firebase wires it; login/logout specs wait on that

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Documentation and full verification

**Files:**
- Modify: `docs/features/e2e-testing.md`, `AGENTS.md:81-83`
- No code.

- [ ] **Step 1: Feature doc**

In `docs/features/e2e-testing.md`:

1. In "How It Works", replace the second paragraph (starting "Authentication uses a real Firebase email/password account") with:

```markdown
Authentication uses three real Firebase email/password accounts: an **admin** (global admin on every
domain), a **normal user** (signed in, never admin, never a member) and a **member** (a plain user with
a comped membership). Five setup projects sign them in through the real login modal and save storage
state; a `seed` project then runs `bin/rails e2e:prepare`, which rebuilds everything database-side
from those rows (roles, membership, seeded reviews and lists, Stripe sandbox plans, the rate limiter)
and writes `e2e/.auth/seed.json`. Every test project depends on `seed`, so a production-dump refresh
needs **no manual E2E steps**: the next run recreates the accounts' rows and state itself.
```

2. Replace the whole "### 2. Firebase Test Account" section, the "### The member account" section and "### 3. Environment File" with:

```markdown
### 2. The three Firebase accounts (one-time)

Create three email/password users in the Firebase console (Authentication → Users → Add user). The
suite never signs up: a signup creates a real account in the shared production Firebase project.

| Account | Role on every run | Membership | Drives |
|---------|-------------------|------------|--------|
| admin   | global `admin`    | none, enforced | music, games, `books-admin` |
| user    | `user`            | none, enforced | `books-account` |
| member  | `user`            | comped, active | `books-member` |

Nothing else to do by hand. The first run's sign-ins create the `User` rows and `e2e:prepare` sets
every cell of that table, cancelling any membership the admin or user holds and comping the member.
`prepare` refuses an email that resolves to an account with a Stripe membership (a real customer),
refuses duplicate emails, and lists any famous slug the specs assume that the catalog no longer has.

### 3. Environment file

`web-app/e2e/.env` (gitignored; copy `e2e/.env.example`):

```env
PLAYWRIGHT_ADMIN_EMAIL=...
PLAYWRIGHT_ADMIN_PASSWORD="..."
PLAYWRIGHT_USER_EMAIL=...
PLAYWRIGHT_USER_PASSWORD="..."
PLAYWRIGHT_MEMBER_EMAIL=...
PLAYWRIGHT_MEMBER_PASSWORD="..."
```

Quote a password containing `#`. There are no ids in this file any more: specs read seeded ids from
`e2e/.auth/seed.json` through `e2e/support/seed.ts`, inside a test or `beforeAll`.

### Per-spec seeds

Some admin specs seed their own rows through rake tasks and clean up after themselves
(`e2e:import_finder_seed`/`_cleanup`, `e2e:reject_link_seed`/`_state`/`_cleanup`,
`e2e:provisional_seed`/`_cleanup`, `e2e:goodreads_import_seed`/`_cleanup`,
`e2e:repair_verdicts_seed`/`_cleanup`, `e2e:list_wizard_cleanup`). All are idempotent. The contact
spec runs `e2e:rate_limit_reset` first, because the contact form allows five anonymous sends per IP
per hour.
```

3. In "Running Tests", add after the first command:

```markdown
`yarn test:e2e` installs Chromium for the pinned Playwright version first (a no-op when present), so a
Playwright upgrade cannot kill the suite before its first page.
```

4. In "Troubleshooting", delete the section "### Auth setup passes but admin tests time out on the public homepage" (its cause is gone) and replace it with:

```markdown
### The seed project fails
Read its output: `e2e:prepare` prints one line per step and aborts with the refusing step's message
(no User for an email → that sign-in failed; a Stripe membership → wrong email in `.env`; catalog
preflight → a slug the specs assume has changed). Fix the cause; there is no manual rake step to run.
```

5. Replace the "Future Improvements" list with:

```markdown
## Future Improvements
- CI: a staging stack (Rails, Sidekiq, Redis, OpenSearch, Caddy, restored database) with a self-hosted
  runner. Out of scope on 2026-10-10; this suite needs no changes to run there.
- Cross-browser projects (Firefox, WebKit)
```

6. Update the directory tree: under `auth/`, list `auth.setup.ts`, `games-auth.setup.ts`, `books-auth.setup.ts`, `books-user-auth.setup.ts`, `books-member-auth.setup.ts`, `seed.setup.ts`; add `support/sign-in.ts` and `support/seed.ts`; under `.auth/` add `seed.json`.

- [ ] **Step 2: AGENTS.md**

In `AGENTS.md`, after the sentence ending "the cost of losing it is just far lower than this section used to claim." (line 83), add:

```markdown
A refresh needs no E2E steps: `yarn test:e2e` runs `bin/rails e2e:prepare` itself, which rebuilds the
three Playwright accounts' roles, membership, seed data and Stripe sandbox plans from nothing.
```

- [ ] **Step 3: Rails suite and lint**

Run: `cd web-app && bin/rails test && bundle exec standardrb`
Expected: green, no new warning lines, no offenses.

- [ ] **Step 4: Two consecutive full E2E runs**

Port check (Global Constraints). Server and Sidekiq from this worktree (Task 3 Step 7). Then:

```bash
cd web-app && yarn test:e2e 2>&1 | tail -5
yarn test:e2e 2>&1 | tail -5
```

Expected, both times: `0 failed`, `0 did not run`, 505 + 6 setup/seed tests passed (the exact count moves with Task 5's new test). No manual command between the runs.

- [ ] **Step 5: Refresh rehearsal**

Snapshot, delete the three e2e users with everything they own, run once, restore:

```bash
cd web-app && ../bin/snapshot-dev-db.sh --label pre-e2e-rehearsal
bin/rails runner 'emails = %w[PLAYWRIGHT_ADMIN_EMAIL PLAYWRIGHT_USER_EMAIL PLAYWRIGHT_MEMBER_EMAIL].map { |k| File.read("e2e/.env")[/^#{k}=(.*)$/, 1].to_s.strip.delete("\"").downcase }; User.person.where("LOWER(email) IN (?)", emails).find_each { |u| puts "destroying #{u.email} (#{u.id})"; u.destroy! }'
rm -f e2e/.auth/*.json
yarn test:e2e 2>&1 | tail -5
../bin/snapshot-dev-db.sh --restore
```

Expected: the runner destroys three users; the suite is fully green on the first run after; the restore completes. If `destroy!` is blocked by a foreign key, report which one rather than working around it: that is a finding about what a refresh leaves behind.

- [ ] **Step 6: Negative check on the paywall**

With the server up: `bin/rails runner 'u = User.find_by(email: ENV.fetch("E")); u.memberships.create!(source: :comped, status: :active, note: "negative check")'` with `E=<PLAYWRIGHT_USER_EMAIL>` exported, then
`npx playwright test --config=e2e/playwright.config.ts tests/books/account/membership.spec.ts --reporter=list`.
Expected: green, because `seed` runs first and cancels the comp. Then prove the test itself bites: run the same spec with `--project=books-account --no-deps` after re-adding the comp. Expected: "a signed-in non-member is redirected away" fails. Remove the comp by running the seed project again.

- [ ] **Step 7: Commit docs and report**

```bash
git add docs/features/e2e-testing.md AGENTS.md
git commit -m "Docs: E2E suite rebuilds its accounts on every run; refresh needs no manual steps

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Stop the server and Sidekiq you started (`pkill -f "rails server -p 3000"; pkill -f sidekiq` only if `readlink /proc/$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)/cwd` is this worktree). Report the two full-run tallies and the rehearsal result verbatim. Do not push or open a PR; ask.
