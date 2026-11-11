require "test_helper"

class ErrorPagesTest < ActiveSupport::TestCase
  def env_for(path, accept: "text/html")
    Rack::MockRequest.env_for(path, "HTTP_ACCEPT" => accept, "HTTP_HOST" => "dev-new.thegreatestbooks.org")
  end

  def body_of(response)
    response[2].each.to_a.join
  end

  test "a 404 for an html request goes to the errors controller" do
    ErrorsController.expects(:action).with(:not_found).returns(->(_env) { [404, {}, ["dynamic"]] })

    status, _headers, body = ErrorPages.call(env_for("/404"))

    assert_equal 404, status
    assert_equal ["dynamic"], body
  end

  test "a 404 falls back to the static page when the dynamic one raises" do
    ErrorsController.expects(:action).with(:not_found).returns(->(_env) { raise "layout exploded" })

    response = ErrorPages.call(env_for("/404"))

    assert_equal 404, response[0]
    assert_includes body_of(response), "<!doctype html>"
  end

  test "a 500 is always the static page, never a render through the app" do
    ErrorsController.expects(:action).never

    response = ErrorPages.call(env_for("/500"))

    assert_equal 500, response[0]
    assert_includes body_of(response), "<!doctype html>"
  end

  test "a 404 for a json request is the static json body" do
    ErrorsController.expects(:action).never

    response = ErrorPages.call(env_for("/404", accept: "application/json"))

    assert_equal 404, response[0]
    assert_equal 404, JSON.parse(body_of(response))["status"]
  end
end
