# frozen_string_literal: true

require "test_helper"

module PageFetcher
  class ExceptionsTest < ActiveSupport::TestCase
    test "every client failure, a tripped breaker included, is a PageFetcher::Exceptions::Error" do
      [
        Exceptions::ConfigurationError, Exceptions::NetworkError, Exceptions::TimeoutError,
        Exceptions::HttpError, Exceptions::ClientError, Exceptions::ServerError,
        Exceptions::UpstreamError, Exceptions::ParseError, Exceptions::CircuitOpenError
      ].each { |error_class| assert_operator error_class, :<, Exceptions::Error }
    end

    test "client, server and upstream errors are siblings, not parent/child" do
      assert_not_operator Exceptions::UpstreamError, :<, Exceptions::ServerError
      assert_not_operator Exceptions::UpstreamError, :<, Exceptions::ClientError
    end

    test "the circuit-open error is not catchable as an Open Library error" do
      assert_not_operator Exceptions::CircuitOpenError, :<, Books::OpenLibrary::Exceptions::Error
    end

    test "an HTTP error carries the status, the body and the service's error code" do
      error = Exceptions::UpstreamError.new("upstream_unreachable: gone", 502, "{}", error_code: "upstream_unreachable")

      assert_equal [502, "{}", "upstream_unreachable"], [error.status_code, error.response_body, error.error_code]
    end

    test "the error code is optional" do
      assert_nil Exceptions::ClientError.new("HTTP 422", 422).error_code
    end
  end
end
