ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"
require "sidekiq/testing"
require "webmock/minitest"
require_relative "support/turbo_frame_links"

# Configure Sidekiq to run jobs inline during tests
Sidekiq::Testing.inline!

# Configure WebMock to prevent real HTTP requests during tests
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

module ActionDispatch
  class IntegrationTest
    def sign_in_as(user, stub_auth: false)
      # Stub authentication service to bypass JWT validation if requested
      if stub_auth
        Services::AuthenticationService.stubs(:call).returns(
          success: true,
          user: user,
          provider_data: {}
        )
      end

      post auth_sign_in_path, params: {
        jwt: "test_token",
        provider: "google",
        user_data: {email: user.email, name: user.name}
      }, as: :json
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
