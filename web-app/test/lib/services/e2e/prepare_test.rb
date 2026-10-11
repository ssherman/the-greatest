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
        Prepare.call(emails: emails,
          manifest_path: @manifest_path,
          review_target: 5,
          anchor_slug: "war-and-peace",
          required_slugs: {books: %w[war-and-peace], books_categories: %w[fiction], games_categories: []},
          sync_plans: sync,
          rate_limit_store: @store, **overrides)
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
        first = [@member.memberships.count, @user.reviews.count, ::Books::UserList.where(user: @user, name: [Prepare::PUBLIC_LIST_NAME, Prepare::PRIVATE_LIST_NAME]).count]
        prepare
        second = [@member.memberships.count, @user.reviews.count, ::Books::UserList.where(user: @user, name: [Prepare::PUBLIC_LIST_NAME, Prepare::PRIVATE_LIST_NAME]).count]
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
        assert_equal [1, 2, 3, 4, 5], reviews.pluck(:rating).map { |r| Review.rating_bucket(r) }.sort
        assert reviews.pluck(:rating).any? { |r| r.to_d % 1 != 0 }, "some seeded ratings are fractional"
        assert reviews.exists?(reviewable: books_books(:war_and_peace))
      end

      test "touches no other user's reviews or lists" do
        @bystander.reviews.create!(reviewable: books_books(:war_and_peace), rating: 4)
        before = [@bystander.reviews.count, ::Books::UserList.where(user: @bystander).count]

        prepare

        assert_equal before, [@bystander.reviews.count, ::Books::UserList.where(user: @bystander).count]
      end

      test "recreates the public and private lists with items and reports their ids" do
        old = ::Books::UserList.create!(user: @user, name: Prepare::PUBLIC_LIST_NAME, list_type: :custom, public: false)

        result = prepare
        assert result.success?, result.errors.inspect

        public_list = ::Books::UserList.find(result.data[:lists][:public_books])
        private_list = ::Books::UserList.find(result.data[:lists][:private_books])
        assert_not ::Books::UserList.exists?(old.id)
        assert_equal [Prepare::PUBLIC_LIST_NAME, true, 3], [public_list.name, public_list.public, public_list.user_list_items.count]
        assert_equal [Prepare::PRIVATE_LIST_NAME, false, 1], [private_list.name, private_list.public, private_list.user_list_items.count]
        assert_equal @user, public_list.user
      end

      test "empties the account's default lists but leaves other users' lists alone" do
        stray = ::Books::UserList.find_by!(user: @user, list_type: :read)
        stray.user_list_items.create!(listable: books_books(:war_and_peace))
        bystander_list = ::Books::UserList.find_by!(user: @bystander, list_type: :read)
        bystander_list.user_list_items.create!(listable: books_books(:war_and_peace))

        result = prepare
        assert result.success?, result.errors.inspect

        assert_equal 0, stray.reload.user_list_items.count
        assert_equal 1, bystander_list.reload.user_list_items.count
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
