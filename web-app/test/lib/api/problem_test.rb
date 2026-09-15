require "test_helper"

module Api
  class ProblemTest < ActiveSupport::TestCase
    setup { Current.domain = :books }

    test "every code has a status and a title" do
      Problem::CODES.each do |code|
        problem = Problem.new(code)
        assert_kind_of Integer, problem.status
        assert problem.title.present?, "#{code} has no title"
      end
    end

    test "the statuses match RFC 6750 and the spec" do
      assert_equal 401, Problem.new(:unauthenticated).status
      assert_equal 401, Problem.new(:invalid_token).status
      assert_equal 403, Problem.new(:membership_required).status
      assert_equal 403, Problem.new(:insufficient_scope).status
      assert_equal 404, Problem.new(:not_found).status
      assert_equal 400, Problem.new(:invalid_parameter).status
      assert_equal 429, Problem.new(:rate_limited).status
    end

    test "to_h is an RFC 9457 body with a stable code and a type on this host's docs page" do
      body = Problem.new(:rate_limited, detail: "Slow down.").to_h

      assert_equal "https://dev-new.thegreatestbooks.org/developers#errors-rate_limited", body[:type]
      assert_equal "Rate limit exceeded", body[:title]
      assert_equal 429, body[:status]
      assert_equal "rate_limited", body[:code]
      assert_equal "Slow down.", body[:detail]
    end

    test "detail is omitted, not null, when absent" do
      refute Problem.new(:not_found).to_h.key?(:detail)
    end

    test "an unknown code raises at construction" do
      assert_raises(KeyError) { Problem.new(:teapot) }
    end
  end
end
