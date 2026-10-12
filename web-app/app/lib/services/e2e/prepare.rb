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
    # It never touches a table, and it refuses (before any write) production
    # and any account that looks like a real person's: a Stripe or legacy
    # membership, a legacy migration, a duplicated email, or staff in a user slot.
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
      # Books that other specs require to have NO reviews from anyone: the
      # reviews specs write and remove their own review on headlong-hall and
      # assert the book starts empty. A human review left there (it has
      # happened) must fail in one line here, not in four specs.
      SCRATCH_BOOK_SLUGS = %w[headlong-hall].freeze

      # The corrections spec applies this subtitle to headlong-hall (which has
      # none otherwise) and never reverts it; a second run would then submit a
      # correction that changes nothing and be refused. Only this exact value is
      # cleared, so a real subtitle is never touched. Keep in sync with
      # SUBTITLE_MARKER in e2e/tests/books/admin/corrections.spec.ts.
      SCRATCH_SUBTITLE_MARKER = "A Gothic Satire [e2e-corrections-spec]"
      # Scratch rows for the book-page trail and admin merge specs. Nearest
      # first; the last is a root, so the book page shows only the first two.
      LOCATION_TRAIL = ["E2E Scratch Town", "E2E Scratch Region", "E2E Scratch Country"].freeze
      MERGE_TARGET_NAME = "E2E Merge Target"
      ROLES = {admin: :admin, user: :user, member: :user}.freeze

      def self.call(**) = new(**).call

      def initialize(emails:, manifest_path:, review_target: REVIEW_TARGET, anchor_slug: ANCHOR_SLUG,
        required_slugs: REQUIRED_SLUGS, scratch_book_slugs: SCRATCH_BOOK_SLUGS, sync_plans: ::Services::Billing::SyncPlans,
        rate_limit_store: Rails.application.config.x.rate_limit_store, log: ->(_line) {})
        @emails = emails.slice(:admin, :user, :member)
        @manifest_path = Pathname(manifest_path)
        @review_target = review_target
        @anchor_slug = anchor_slug
        @required_slugs = required_slugs
        @scratch_book_slugs = scratch_book_slugs
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
        clear_scratch_books(accounts)
        seed_category_scratch
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
        :scratch_book_slugs, :sync_plans, :rate_limit_store, :log

      def failure(errors) = Result.new(success?: false, data: nil, errors: errors)

      # Every check here runs before any write, so a bad .env changes nothing.
      def resolve_accounts(errors)
        if Rails.env.production?
          errors << "e2e:prepare never runs in production"
          return {}
        end
        missing_keys = ROLES.keys - emails.keys
        if missing_keys.any?
          errors << "missing e2e account emails: #{missing_keys.join(", ")}"
          return {}
        end
        if emails.values.map { |e| e.to_s.downcase }.uniq.size != ROLES.size
          errors << "the three e2e accounts must have three different emails (got #{emails.values.join(", ")})"
          return {}
        end

        emails.to_h do |key, email|
          matches = ::User.person.where("LOWER(email) = ?", email.to_s.downcase).order(:id).to_a
          user = matches.first
          if user.nil?
            errors << "no User for #{email}; the seed project signs it in first (a browser sign-in creates the row)"
          elsif matches.size > 1
            errors << "#{matches.size} User rows share #{email}; refusing to guess"
          else
            errors.concat(refusals_for(key, email, user))
          end
          [key, user]
        end
      end

      # An e2e account is a plain throwaway sign-in. Anything that marks the row
      # as a real person's (a paying or legacy membership, a legacy migration,
      # a staff role in a slot that should hold a plain user) means the .env
      # address is wrong, and prepare deletes reviews and list items for it.
      def refusals_for(key, email, user)
        refusals = []
        if user.memberships.source_stripe.exists?
          refusals << "#{email} holds a Stripe membership, so it is a real customer, not an e2e account; refusing to touch it"
        end
        if user.memberships.source_legacy.exists?
          refusals << "#{email} holds a legacy membership, so it is a real customer, not an e2e account; refusing to touch it"
        end
        if user.legacy_migrated == true || user.legacy_v1_data.present?
          refusals << "#{email} was migrated from the legacy site, so it is a real person, not an e2e account; refusing to touch it"
        end
        if key != :admin && %w[admin editor].include?(user.role)
          refusals << "#{email} is currently #{user.role}; the user/member slots must be plain users (is this the right address?)"
        end
        refusals
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
        books = ::Books::Book.where.not(slug: EXCLUDED_REVIEW_SLUGS + scratch_book_slugs).where.not(id: anchor.id).order(:id).limit(needed).to_a
        raise SeedError, "only #{books.size} books available for #{needed} seed reviews" if books.size < needed

        lookalike = books.find { |book| book.title.to_s.match?(/animal farm/i) }
        raise SeedError, "seed book ##{lookalike.id} (#{lookalike.title}) would be a second 'Animal Farm' search hit" if lookalike

        # (i % 5) + 1 after a rating-5 anchor gives six per rating at 30.
        # Every third review is a quarter under its whole star (4.75, 0.75, ...);
        # that stays in the same bucket (Review.rating_bucket), so the my-reviews
        # rating-bar test sees fractional values without the per-rating split changing.
        books.each_with_index do |book, i|
          rating = (i % 5) + 1
          rating -= 0.25 if (i % 3).zero?
          user.reviews.create!(reviewable: book, rating: rating,
            body: i.odd? ? "Seed review #{i} for the E2E /my/reviews spec." : nil)
        end
        log.call("#{user.email}: #{review_target} Books::Book reviews")
      end

      def reset_lists(user)
        # A failed run can leave books on this account's default lists (reading
        # goals add to Read/Reading); the next run must start from empty lists.
        ::Books::UserList.where(user: user).find_each { |list| list.user_list_items.each(&:destroy!) }

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
        scratch_errors = scratch_book_errors
        errors.concat(scratch_errors)
        if missing.any?
          errors << "catalog preflight: missing #{missing.join(", ")}"
        elsif scratch_errors.empty?
          log.call("catalog preflight: #{required_slugs.values.sum(&:size)} slug(s) present")
        end
      end

      # The e2e accounts' own reviews on scratch books are disposable: a spec
      # that died mid-run leaves them, and the next run must start clean.
      def clear_scratch_books(accounts)
        scratch_books.each do |book|
          ::Review.where(reviewable: book, user: accounts.values).each(&:destroy!)
          book.update!(subtitle: nil) if book.subtitle == SCRATCH_SUBTITLE_MARKER
        end
      end

      # Idempotent. Touches only the scratch book and categories it names.
      def seed_category_scratch
        book = scratch_books.first
        return if book.nil?

        parent = nil
        LOCATION_TRAIL.reverse_each do |name|
          category = ::Books::Category.find_or_create_by!(name: name, category_type: :location, deleted: false)
          category.update!(parent_id: parent&.id) if category.parent_id != parent&.id
          parent = category
        end
        link = ::CategoryItem.find_or_initialize_by(category: parent, item: book)
        link.update!(source: :admin)
        ::Categories::AncestorReconciler.call(item_ids: [book.id])
        target = ::Books::Category.find_or_create_by!(name: MERGE_TARGET_NAME, category_type: :location, deleted: false)
        # The merge spec appends its source name to this every run.
        target.update!(alternative_names: []) if target.alternative_names.present?
      end

      # Anyone else's review on a scratch book is reported, never deleted:
      # it is a human's data on a shared development database.
      def scratch_book_errors
        scratch_books.filter_map do |book|
          reviews = ::Review.where(reviewable: book).includes(:user).to_a
          next if reviews.empty?

          emails = reviews.map { |review| review.user.email }.sort.join(", ")
          "Books::Book #{book.slug} has #{reviews.size} review(s) by non-e2e users: #{emails}; " \
            "the reviews specs need it review-free -- delete or move them"
        end
      end

      def scratch_books
        scratch_book_slugs.filter_map { |slug| ::Books::Book.find_by(slug: slug) }
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
