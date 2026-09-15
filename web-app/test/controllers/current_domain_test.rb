require "test_helper"

class CurrentDomainTest < ActionDispatch::IntegrationTest
  test "a books host sets Current.domain to books" do
    host! "dev-new.thegreatestbooks.org"
    get "/privacy_policy"

    assert_response :success
    assert_equal :books, @controller.send(:current_domain)
    assert_equal "The Greatest Books", @controller.send(:domain_settings)[:name]
  end

  test "a music host sets Current.domain to music" do
    host! "dev.thegreatestmusic.org"
    get "/privacy_policy"

    assert_response :success
    assert_equal :music, @controller.send(:current_domain)
  end

  test "the concern is what ApplicationController uses" do
    assert_includes ApplicationController.ancestors, CurrentDomain
  end
end
