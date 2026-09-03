require "test_helper"

class FirebaseTokenHelperTest < ActiveSupport::TestCase
  test "produces a token the real JWT decoder verifies against the real certificate" do
    token = FirebaseTokenHelper.token
    cert = OpenSSL::X509::Certificate.new(FirebaseTokenHelper.certificate_pem)

    payload, header = JWT.decode(token, cert.public_key, true, {algorithm: "RS256"})

    assert_equal "RS256", header["alg"]
    assert_equal FirebaseTokenHelper::DEFAULT_KID, header["kid"]
    assert_equal FirebaseTokenHelper.project_id, payload["aud"]
    assert_equal FirebaseTokenHelper.issuer, payload["iss"]
    assert_equal "firebase-uid-abc", payload["sub"]
  end

  test "a token signed by a foreign key fails verification against our certificate" do
    foreign = OpenSSL::PKey::RSA.new(2048)
    token = FirebaseTokenHelper.token(signing_key: foreign)
    cert = OpenSSL::X509::Certificate.new(FirebaseTokenHelper.certificate_pem)

    assert_raises JWT::VerificationError do
      JWT.decode(token, cert.public_key, true, {algorithm: "RS256"})
    end
  end
end
