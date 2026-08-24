# frozen_string_literal: true

require "test_helper"

module Services
  module Amazon
    class ClientTest < ActiveSupport::TestCase
      # Minimal stand-ins for HTTP::Response / Vacuum::Client. We assert on our
      # own behaviour (what Client returns and raises), never on these doubles.
      FakeStatus = Struct.new(:code, :success?)

      class FakeResponse
        attr_reader :status, :body

        def initialize(code:, payload:)
          @status = FakeStatus.new(code, (200..299).cover?(code))
          @payload = payload
          @body = payload.to_json
        end

        def parse = @payload
      end

      class FakeVacuum
        attr_reader :calls

        def initialize(response)
          @response = response
          @calls = []
        end

        def search_items(**params)
          @calls << params
          @response
        end
      end

      def setup
        @env = {
          "AMAZON_PRODUCT_API_CRED_ID" => "amzn1.test-cred",
          "AMAZON_PRODUCT_API_SECRET" => "amzn1.test-secret",
          "AMAZON_PRODUCT_API_PARTNER_KEY" => "testtag-20"
        }
      end

      def with_env(overrides = {})
        merged = @env.merge(overrides)
        original = merged.keys.index_with { |k| ENV[k] }
        merged.each { |k, v| ENV[k] = v }
        yield
      ensure
        original.each { |k, v| ENV[k] = v }
      end

      def stub_vacuum(code:, payload:)
        fake = FakeVacuum.new(FakeResponse.new(code: code, payload: payload))
        ::Vacuum.stubs(:new).returns(fake)
        fake
      end

      test "search_items returns the items from a successful response" do
        stub_vacuum(code: 200, payload: {"searchResult" => {"items" => [{"asin" => "B001"}, {"asin" => "B002"}]}})

        items = with_env { Client.search_items(keywords: "Kid A") }

        assert_equal ["B001", "B002"], items.map { |i| i["asin"] }
      end

      test "search_items returns an empty array when the response carries no items" do
        stub_vacuum(code: 200, payload: {"searchResult" => {}})

        assert_equal [], with_env { Client.search_items(keywords: "nothing matches this") }
      end

      # This is the regression that let PA-API's shutdown go unnoticed for months:
      # a non-2xx body digs to nil, which the callers read as "no products found".
      test "search_items raises on a non-success response instead of returning no items" do
        stub_vacuum(code: 403, payload: {"message" => "Product Advertising API is deprecated."})

        error = assert_raises(Client::Error) do
          with_env { Client.search_items(keywords: "Kid A") }
        end

        assert_match(/403/, error.message)
        assert_match(/deprecated/, error.message)
      end

      test "search_items raises when credentials are not configured" do
        stub_vacuum(code: 200, payload: {"searchResult" => {"items" => []}})

        error = assert_raises(Client::Error) do
          with_env("AMAZON_PRODUCT_API_CRED_ID" => nil) { Client.search_items(keywords: "Kid A") }
        end

        assert_match(/credentials/i, error.message)
      end

      test "search_items sends the marketplace and partner tag Amazon requires on every request" do
        fake = stub_vacuum(code: 200, payload: {"searchResult" => {"items" => []}})

        with_env { Client.search_items(keywords: "Kid A", search_index: "Music") }

        assert_equal 1, fake.calls.size
        assert_equal "www.amazon.com", fake.calls.first[:marketplace]
        assert_equal "testtag-20", fake.calls.first[:partner_tag]
        assert_equal "Music", fake.calls.first[:search_index]
      end

      test "search_items builds the client with the Login with Amazon credential version" do
        ::Vacuum.expects(:new).with(
          has_entries(credential_id: "amzn1.test-cred", credential_secret: "amzn1.test-secret", version: "3.1")
        ).returns(FakeVacuum.new(FakeResponse.new(code: 200, payload: {"searchResult" => {"items" => []}})))

        with_env { Client.search_items(keywords: "Kid A") }
      end
    end
  end
end
