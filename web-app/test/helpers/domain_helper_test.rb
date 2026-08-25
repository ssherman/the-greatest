# frozen_string_literal: true

require "test_helper"

class DomainHelperTest < ActionView::TestCase
  include DomainHelper

  test "domain_js_bundle names the current domain's web bundle" do
    stubs(:current_domain).returns(:books)
    assert_equal "books-web", domain_js_bundle
  end

  test "domain_js_bundle follows the current domain" do
    stubs(:current_domain).returns(:games)
    assert_equal "games-web", domain_js_bundle
  end
end
