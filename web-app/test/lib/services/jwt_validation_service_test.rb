require "test_helper"
require "jwt"

class JwtValidationServiceTest < ActiveSupport::TestCase
  def setup
    Services::JwtValidationService.reset_cert_cache!
    @project_id = Rails.application.config.x.firebase_project_id
    FirebaseTokenHelper.stub_certs
  end

  def call(token)
    Services::JwtValidationService.call(token, project_id: @project_id)
  end

  test "accepts a well-formed token and returns its payload" do
    payload = call(FirebaseTokenHelper.token)

    assert_equal "firebase-uid-abc", payload["sub"]
    assert_equal "someone@example.com", payload["email"]
    assert_equal @project_id, payload["aud"]
  end

  test "project_id is required -- omitting it is an ArgumentError, not a skipped check" do
    assert_raises ArgumentError do
      Services::JwtValidationService.call(FirebaseTokenHelper.token)
    end
  end

  # F1. Before this, project_id defaulted to nil and AuthController never passed
  # one, so a token from any Firebase project on earth validated.
  test "rejects a token minted for a different Firebase project" do
    token = FirebaseTokenHelper.token({"aud" => "someone-elses-project"})

    assert_raises JWT::InvalidAudError do
      call(token)
    end
  end

  test "rejects a token whose issuer is not our project" do
    token = FirebaseTokenHelper.token({"iss" => "https://securetoken.google.com/someone-elses-project"})

    assert_raises JWT::InvalidIssuerError do
      call(token)
    end
  end

  # The legacy app is exploitable exactly here: it read alg from the header.
  test "rejects an unsigned alg=none token" do
    token = FirebaseTokenHelper.token({}, alg: "none")

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "rejects a token signed by a key that is not Google's" do
    foreign = OpenSSL::PKey::RSA.new(2048)
    token = FirebaseTokenHelper.token(signing_key: foreign)

    assert_raises JWT::VerificationError do
      call(token)
    end
  end

  test "rejects an expired token" do
    token = FirebaseTokenHelper.token({"exp" => Time.now.to_i - 60})

    assert_raises JWT::ExpiredSignature do
      call(token)
    end
  end

  test "rejects a token with a blank subject" do
    token = FirebaseTokenHelper.token({"sub" => ""})

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "rejects a token whose kid is not in Google's certificate set" do
    token = FirebaseTokenHelper.token(kid: "some-other-kid")

    assert_raises JWT::DecodeError do
      call(token)
    end
  end

  test "raises when Google's certificate endpoint fails" do
    WebMock.stub_request(:get, Services::JwtValidationService::GOOGLE_CERTS_URL)
      .to_return(status: 500, body: "")

    assert_raises JWT::DecodeError do
      call(FirebaseTokenHelper.token)
    end
  end

  test "fetches Google's certificates once across repeated validations" do
    3.times { call(FirebaseTokenHelper.token) }

    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 1
  end

  test "refetches once the Cache-Control max-age has passed" do
    FirebaseTokenHelper.stub_certs(max_age: 60)
    call(FirebaseTokenHelper.token)

    travel 61.seconds do
      call(FirebaseTokenHelper.token)
    end

    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 2
  end

  test "refetches when the kid is absent from the cached set" do
    call(FirebaseTokenHelper.token)

    # A rotated key: present in the fresh response, absent from what we cached.
    assert_raises JWT::DecodeError do
      call(FirebaseTokenHelper.token(kid: "rotated-kid"))
    end
    assert_requested :get, Services::JwtValidationService::GOOGLE_CERTS_URL, times: 2
  end
end
