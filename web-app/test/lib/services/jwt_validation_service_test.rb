require "test_helper"
require "jwt"
require_relative "../../../app/lib/services/jwt_validation_service"

class JwtValidationServiceTest < ActiveSupport::TestCase
  def setup
    @valid_token = "eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3Rfa2V5X2lkIn0.eyJhdWQiOiJ0ZXN0LXByb2plY3QiLCJpc3MiOiJodHRwczovL3NlY3VyZXRva2VuLmdvb2dsZS5jb20vdGVzdC1wcm9qZWN0Iiwic3ViIjoidGVzdF91c2VyX2lkIiwiaWF0IjoxNjM1NzI5NjAwLCJleHAiOjE2MzU3MzMyMDAsImF1dGhfdGltZSI6MTYzNTcyOTYwMH0.test_signature"
    @google_certs_response = {
      "test_key_id" => "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...\n-----END CERTIFICATE-----"
    }.to_json
  end

  test "successfully validates a valid JWT token" do
    # Mock JWT.decode to return our test data
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {"aud" => "test-project", "sub" => "test_user_id", "iat" => 1635729600, "exp" => 1635733200},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock OpenSSL certificate creation
    mock_cert = mock
    mock_public_key = mock
    mock_cert.stubs(:public_key).returns(mock_public_key)
    OpenSSL::X509::Certificate.stubs(:new).returns(mock_cert)

    # Mock the second JWT.decode call (with public key)
    JWT.stubs(:decode).with(@valid_token, mock_public_key, true, {algorithm: "RS256", aud: nil}).returns([
      {"aud" => "test-project", "sub" => "test_user_id", "iat" => 1635729600, "exp" => 1635733200},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock Faraday response
    mock_response = mock
    mock_response.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns(@google_certs_response)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    result = ::JwtValidationService.call(@valid_token)

    assert_equal "test-project", result["aud"]
    assert_equal "test_user_id", result["sub"]
  end

  test "validates project_id when provided" do
    # Mock JWT.decode calls
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {"aud" => "test-project", "sub" => "test_user_id"},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock OpenSSL certificate creation
    mock_cert = mock
    mock_public_key = mock
    mock_cert.stubs(:public_key).returns(mock_public_key)
    OpenSSL::X509::Certificate.stubs(:new).returns(mock_cert)

    JWT.stubs(:decode).with(@valid_token, mock_public_key, true, {algorithm: "RS256", aud: "test-project"}).returns([
      {"aud" => "test-project", "sub" => "test_user_id"},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock Faraday response
    mock_response = mock
    mock_response.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns(@google_certs_response)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    result = ::JwtValidationService.call(@valid_token, project_id: "test-project")
    assert_equal "test-project", result["aud"]
  end

  test "raises error when project_id does not match" do
    # Mock JWT.decode calls
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {"aud" => "wrong-project", "sub" => "test_user_id"},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock OpenSSL certificate creation
    mock_cert = mock
    mock_public_key = mock
    mock_cert.stubs(:public_key).returns(mock_public_key)
    OpenSSL::X509::Certificate.stubs(:new).returns(mock_cert)

    JWT.stubs(:decode).with(@valid_token, mock_public_key, true, {algorithm: "RS256", aud: "test-project"}).returns([
      {"aud" => "wrong-project", "sub" => "test_user_id"},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock Faraday response
    mock_response = mock
    mock_response.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns(@google_certs_response)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    assert_raises JWT::InvalidAudError do
      ::JwtValidationService.call(@valid_token, project_id: "test-project")
    end
  end

  test "raises error when Faraday request fails" do
    # Mock JWT.decode for header extraction
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock failed Faraday response
    mock_response = mock
    mock_response.stubs(:success?).returns(false)
    mock_response.stubs(:status).returns(500)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    assert_raises JWT::DecodeError do
      ::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when key ID is not found in certificates" do
    # Mock JWT.decode for header extraction
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {},
      {"kid" => "unknown_key_id", "alg" => "RS256"}
    ])

    # Mock successful Faraday response with different key
    mock_response = mock
    mock_response.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns(@google_certs_response)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    assert_raises JWT::DecodeError do
      ::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when JWT decode fails" do
    JWT.stubs(:decode).with(@valid_token, nil, false).raises(JWT::DecodeError.new("Invalid token"))

    assert_raises JWT::DecodeError do
      ::JwtValidationService.call(@valid_token)
    end
  end

  test "raises error when certificate creation fails" do
    # Mock JWT.decode for header extraction
    JWT.stubs(:decode).with(@valid_token, nil, false).returns([
      {},
      {"kid" => "test_key_id", "alg" => "RS256"}
    ])

    # Mock successful Faraday response
    mock_response = mock
    mock_response.stubs(:success?).returns(true)
    mock_response.stubs(:body).returns(@google_certs_response)
    Faraday.stubs(:get).with(::JwtValidationService::GOOGLE_CERTS_URL).returns(mock_response)

    # Mock certificate creation failure
    OpenSSL::X509::Certificate.stubs(:new).raises(OpenSSL::X509::CertificateError.new("Invalid certificate"))

    assert_raises OpenSSL::X509::CertificateError do
      ::JwtValidationService.call(@valid_token)
    end
  end
end
