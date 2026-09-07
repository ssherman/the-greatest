require "test_helper"

class FirebaseAccountLookupTest < ActiveSupport::TestCase
  PROJECT = "the-greatest-books"

  def setup
    Services::GoogleServiceAccountToken.stubs(:access_token).returns("ya29.token")
  end

  def stub_lookup(status: 200, body: nil)
    body ||= {
      users: [{
        localId: "skDlsJ347BRgwmZNMfJ28465YU23",
        providerUserInfo: [
          {providerId: "facebook.com", rawId: "10166754100896840", email: "shane@example.com"}
        ]
      }]
    }
    response = mock
    response.stubs(:status).returns(status)
    response.stubs(:body).returns(JSON.generate(body))
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)
    connection
  end

  test "returns the provider entries for the account" do
    stub_lookup

    entries = Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)

    assert_equal 1, entries.size
    assert_equal "facebook.com", entries.first["providerId"]
    assert_equal "shane@example.com", entries.first["email"]
  end

  test "posts the uid as localId to the project's lookup endpoint with a bearer token" do
    response = stub(status: 200, body: JSON.generate(users: [{providerUserInfo: []}]))
    request = mock
    headers = {}
    request.stubs(:headers).returns(headers)
    request.expects(:body=).with(JSON.generate(localId: ["uid_1"]))
    connection = mock
    connection.expects(:post).with("/v1/projects/#{PROJECT}/accounts:lookup").yields(request).returns(response)
    Faraday.stubs(:new).returns(connection)

    Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)

    assert_equal "Bearer ya29.token", headers["Authorization"]
  end

  test "an account with no provider entries returns an empty array, not nil" do
    stub_lookup(body: {users: [{localId: "uid_1"}]})

    assert_equal [], Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
  end

  test "an unknown account returns an empty array" do
    stub_lookup(body: {})

    assert_equal [], Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
  end

  test "a non-200 raises" do
    stub_lookup(status: 403, body: {error: {message: "PERMISSION_DENIED"}})

    error = assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
    assert_match(/403/, error.message)
  end

  test "an unparseable body raises" do
    response = mock
    response.stubs(:status).returns(200)
    response.stubs(:body).returns("<html>gateway error</html>")
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
  end

  test "a timeout raises the service's own error, not Faraday's" do
    connection = mock
    connection.stubs(:post).raises(Faraday::TimeoutError)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("uid_1", project_id: PROJECT)
    end
  end

  test "a blank uid raises without making a request" do
    Faraday.expects(:new).never

    assert_raises(Services::FirebaseAccountLookup::Error) do
      Services::FirebaseAccountLookup.call("", project_id: PROJECT)
    end
  end
end
