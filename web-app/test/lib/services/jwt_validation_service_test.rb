require "test_helper"
require "jwt"

class JwtValidationServiceTest < ActiveSupport::TestCase
  def setup
    @valid_token = "valid.jwt.token"
    @valid_payload = {
      "sub" => "user123",
      "email" => "test@example.com",
      "aud" => "test-project",
      "iat" => Time.current.to_i,
      "exp" => (Time.current + 1.hour).to_i
    }
  end

  test "successfully validates a valid JWT token" do
    # Mock the certificate fetching
    mock_cert = mock
    mock_cert.stubs(:public_key).returns(mock)

    Services::JwtValidationService.stubs(:fetch_google_cert).returns(mock_cert)

    # Mock JWT decode to return our test payload
    JWT.stubs(:decode).returns([@valid_payload, {"kid" => "test-key"}])

    result = Services::JwtValidationService.call(@valid_token)

    assert_equal @valid_payload, result
  end

  test "validates project_id when provided" do
    mock_cert = mock
    mock_cert.stubs(:public_key).returns(mock)

    Services::JwtValidationService.stubs(:fetch_google_cert).returns(mock_cert)
    JWT.stubs(:decode).returns([@valid_payload, {"kid" => "test-key"}])

    result = Services::JwtValidationService.call(@valid_token, project_id: "test-project")

    assert_equal @valid_payload, result
  end

  test "raises error when project_id does not match" do
    payload_with_wrong_aud = @valid_payload.merge("aud" => "wrong-project")
    mock_cert = mock
    mock_cert.stubs(:public_key).returns(mock)

    Services::JwtValidationService.stubs(:fetch_google_cert).returns(mock_cert)
    JWT.stubs(:decode).returns([payload_with_wrong_aud, {"kid" => "test-key"}])

    assert_raises JWT::InvalidAudError do
      Services::JwtValidationService.call(@valid_token, project_id: "test-project")
    end
  end

  test "raises error when Faraday request fails" do
    mock_response = mock
    mock_response.stubs(:success?).returns(false)
    mock_response.stubs(:status).returns(500)

    Faraday.stubs(:get).returns(mock_response)

    assert_raises JWT::DecodeError do
      Services::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when key ID is not found in certificates" do
    response_mock = mock
    response_mock.stubs(:success?).returns(true)
    response_mock.stubs(:body).returns('{"other-key": "cert-data"}')

    Faraday.stubs(:get).returns(response_mock)

    assert_raises JWT::DecodeError do
      Services::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when certificate creation fails" do
    response_mock = mock
    response_mock.stubs(:success?).returns(true)
    response_mock.stubs(:body).returns('{"test-key": "invalid-cert-data"}')

    Faraday.stubs(:get).returns(response_mock)
    OpenSSL::X509::Certificate.stubs(:new).raises(OpenSSL::X509::CertificateError.new)

    assert_raises JWT::DecodeError do
      Services::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when JWT decode fails" do
    JWT.stubs(:decode).raises(JWT::DecodeError.new("Invalid token"))

    assert_raises JWT::DecodeError do
      Services::JwtValidationService.call("invalid.token")
    end
  end
end
