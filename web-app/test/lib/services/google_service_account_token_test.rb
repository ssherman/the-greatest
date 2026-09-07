require "test_helper"

class GoogleServiceAccountTokenTest < ActiveSupport::TestCase
  # A throwaway RSA key. Generated per-run rather than checked in so this file
  # never looks like it contains a real credential.
  KEY = OpenSSL::PKey::RSA.generate(2048)

  def setup
    Services::GoogleServiceAccountToken.reset!
    ENV["FIREBASE_SERVICE_ACCOUNT_KEY"] = Base64.strict_encode64(
      JSON.generate(client_email: "svc@example.iam.gserviceaccount.com", private_key: KEY.to_pem)
    )
  end

  def teardown
    Services::GoogleServiceAccountToken.reset!
    ENV.delete("FIREBASE_SERVICE_ACCOUNT_KEY")
  end

  def stub_exchange(status: 200, body: {access_token: "ya29.token", expires_in: 3600})
    response = mock
    response.stubs(:status).returns(status)
    response.stubs(:body).returns(JSON.generate(body))
    connection = mock
    connection.stubs(:post).returns(response)
    Faraday.stubs(:new).returns(connection)
    connection
  end

  test "returns the access token from the exchange" do
    stub_exchange

    assert_equal "ya29.token", Services::GoogleServiceAccountToken.access_token
  end

  test "a second call inside the lifetime issues no second exchange" do
    connection = stub_exchange
    connection.expects(:post).once.returns(
      stub(status: 200, body: JSON.generate(access_token: "ya29.token", expires_in: 3600))
    )

    2.times { Services::GoogleServiceAccountToken.access_token }
  end

  test "a token near expiry is refreshed" do
    stub_exchange(body: {access_token: "first", expires_in: 60})
    assert_equal "first", Services::GoogleServiceAccountToken.access_token

    stub_exchange(body: {access_token: "second", expires_in: 3600})
    assert_equal "second", Services::GoogleServiceAccountToken.access_token,
      "expires_in 60 is inside the 300s refresh buffer, so the next call must re-exchange"
  end

  test "a non-200 exchange raises rather than returning nil" do
    stub_exchange(status: 401, body: {error: "unauthorized_client"})

    error = assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
    assert_match(/401/, error.message)
  end

  test "an exchange with no access_token raises" do
    stub_exchange(body: {expires_in: 3600})

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end

  test "a missing credential raises a named error rather than a NoMethodError" do
    ENV.delete("FIREBASE_SERVICE_ACCOUNT_KEY")

    error = assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
    assert_match(/FIREBASE_SERVICE_ACCOUNT_KEY/, error.message)
  end

  test "a credential that is not base64 JSON raises a named error" do
    ENV["FIREBASE_SERVICE_ACCOUNT_KEY"] = Base64.strict_encode64("not json")

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end

  test "a timeout raises the service's own error, not Faraday's" do
    connection = mock
    connection.stubs(:post).raises(Faraday::TimeoutError)
    Faraday.stubs(:new).returns(connection)

    assert_raises(Services::GoogleServiceAccountToken::Error) do
      Services::GoogleServiceAccountToken.access_token
    end
  end
end
