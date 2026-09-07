ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"
require_relative "support/turbo_frame_links"
require_relative "support/stripe_webhook_helper"
require_relative "support/firebase_token_helper"

# Configure Sidekiq to run jobs inline during tests
# Sidekiq 9 removes `require "sidekiq/testing"`. Sidekiq.testing! loads sidekiq/test_api
# itself, which still defines Sidekiq::Testing.fake!/inline! for per-test overrides.
Sidekiq.testing!(:inline)

# Configure WebMock to prevent real HTTP requests during tests
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Capped, not :number_of_processors. Several agents run suites at once in
    # separate worktrees, and every worker holds one Postgres connection, so an
    # unbounded count per run exhausts the server: measured 2026-08-24, three
    # concurrent runs at 32 workers each produced thousands of
    # ActiveRecord::ConnectionAdapters errors in all three -- scattered through
    # fixture loading, where they read as real breakage. Three overlapping runs
    # saturate the box at any worker count (~80s wall at 10, 16 or 32 alike), so
    # a high count buys nothing exactly when it costs the most.
    #
    # CI runs alone on a 2-4 core runner, where the core count is the right
    # answer. PARALLEL_WORKERS overrides either.
    parallelize(workers: ENV["CI"] ? :number_of_processors : 10)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Books::BookType memoizes its LegacyIdMap lookup at the class level, which
    # would otherwise outlive the per-test transaction and leak an order-dependent
    # value into every later test in the same worker.
    #
    # rate_limit_store.clear belongs here, not inside sign_in_as: sign_in_as is
    # the de facto login path for ~90 other test files, all sharing one worker
    # process and therefore one Rails.application.config.x.rate_limit_store
    # instance (see config/initializers/rate_limit_store.rb) for the life of
    # that worker. AuthController#sign_in is rate-limited, keyed by visitor_ip
    # -- and every integration-test request resolves to the same visitor_ip, so
    # without clearing somewhere, the Nth call to sign_in_as in a worker
    # (N > AuthController::SIGN_IN_RATE within the window) gets a 429 instead
    # of a real sign-in, and every test after it fails as "not signed in" in
    # files that have nothing to do with auth or rate limiting. Clearing here,
    # once per test instead of inside sign_in_as, is what it takes to fix that
    # without also erasing counts a single test builds up deliberately (e.g.
    # reviews_controller_test.rb's "the limit is per user, not global", which
    # posts as one user, then calls sign_in_as for a second user and expects
    # the FIRST user's count to still be there for the assertion to mean
    # anything) -- an in-helper clear wipes the whole store, including buckets
    # that have nothing to do with auth, mid-test.
    #
    # JwtValidationService.reset_cert_cache! belongs here for the same class of
    # reason: the Google cert cache is class-level state shared across every
    # test in a worker. Nothing leaks today, but the failure mode is a test
    # *passing* on a certificate cached by an earlier test that it never
    # stubbed itself -- silent, and only three test files reset it on their
    # own.
    setup do
      ::Books::BookType.reset_category_ids!
      Rails.application.config.x.rate_limit_store.clear
      Services::JwtValidationService.reset_cert_cache!
    end

    # Add more helper methods to be used by all tests here...

    def with_env(vars)
      original = vars.keys.index_with { |key| ENV[key] }
      vars.each { |key, value| ENV[key] = value }
      yield
    ensure
      original.each { |key, value| ENV[key] = value }
    end
  end
end

module ActionDispatch
  class IntegrationTest
    include StripeWebhookHelper

    def sign_in_as(user, stub_auth: false)
      # Stub authentication service to bypass JWT validation if requested
      if stub_auth
        Services::AuthenticationService.stubs(:call).returns(
          success: true,
          user: user,
          provider_data: {}
        )
      end

      post auth_sign_in_path, params: {jwt: "test_token"}, as: :json
    end

    # Fails when a link on `path` would navigate a Turbo Frame that its
    # destination doesn't contain — Turbo drops the response and writes
    # "Content missing" into the frame instead of navigating.
    #
    # Issues its own requests and so clobbers `response`; give it its own test.
    def assert_no_frame_trapped_links(path)
      get path
      assert_response :success, "expected #{path} to render before inspecting its frames"

      TurboFrameLinks.trapped_candidates(response.body, host: host).each do |candidate|
        get candidate.href
        # Bounded so a redirect cycle fails fast instead of hanging the test.
        # follow_redirect! calls host! on an absolute Location, which retargets
        # this session for every subsequent candidate — harmless today since no
        # covered page redirects cross-host, but worth knowing if one ever does.
        3.times do
          break unless response.redirect?
          follow_redirect!
        end

        assert_response :success,
          "#{candidate.href} (linked inside frame ##{candidate.frame_id} on #{path}) " \
          "returned #{response.status}"

        assert Nokogiri::HTML5(response.body).at_css(%(turbo-frame[id="#{candidate.frame_id}"])),
          "Frame-trapped link on #{path}: <a href=\"#{candidate.href}\"> navigates frame " \
          "##{candidate.frame_id}, but that page contains no such frame, so Turbo renders " \
          "\"Content missing\". Fix it with target: \"_top\" on the frame, or " \
          "data-turbo-frame: \"_top\" on the link."
      end
    end
  end
end
