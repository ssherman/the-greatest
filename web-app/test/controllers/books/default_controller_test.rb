require "test_helper"

class Books::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "should get index for books domain" do
    host! "dev-new.thegreatestbooks.org"
    get books_root_url
    assert_response :success
  end

  test "should use books layout" do
    host! "dev-new.thegreatestbooks.org"
    get books_root_url
    assert_response :success
    assert_select "title", /The Greatest Books/
  end
end
