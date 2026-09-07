require "jwt"
require "openssl"

# Builds real, really-signed Firebase-shaped ID tokens so auth tests exercise
# the actual decoder instead of a stub.
#
# The RSA key and certificate are generated once per process and memoised:
# keygen is ~100ms and the suite runs 10 parallel workers, so per-test
# generation would be the slowest thing in the file. They are immutable after
# creation, so sharing them across tests in a worker is safe.
module FirebaseTokenHelper
  DEFAULT_KID = "test-kid".freeze

  class << self
    # A method, not a constant: this file is require_relative'd from
    # test_helper.rb, and eager_load is off in test, so resolving an autoloaded
    # app constant at module-body evaluation is a Zeitwerk sharp edge. Deferring
    # it to call time sidesteps that entirely.
    def certs_url
      Services::JwtValidationService::GOOGLE_CERTS_URL
    end

    def key
      @key ||= OpenSSL::PKey::RSA.new(2048)
    end

    def certificate
      @certificate ||= begin
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=firebase-test")
        cert.issuer = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now - 3600
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert
      end
    end

    def certificate_pem
      certificate.to_pem
    end

    def project_id
      Rails.application.config.x.firebase_project_id
    end

    def issuer
      Rails.application.config.x.firebase_issuer
    end

    # A well-formed Firebase ID token. Pass overrides to break exactly one
    # claim at a time; pass alg: "none" or a foreign key to forge.
    def token(overrides = {}, kid: DEFAULT_KID, alg: "RS256", signing_key: key)
      now = Time.now.to_i
      payload = {
        "iss" => issuer,
        "aud" => project_id,
        "sub" => "firebase-uid-abc",
        "email" => "someone@example.com",
        "email_verified" => true,
        "name" => "Some One",
        "picture" => "https://example.com/p.jpg",
        "auth_time" => now,
        "iat" => now,
        "exp" => now + 3600,
        "firebase" => {
          "sign_in_provider" => "password",
          "identities" => {"email" => ["someone@example.com"]}
        }
      }.merge(overrides)

      JWT.encode(payload, (alg == "none") ? nil : signing_key, alg, {"kid" => kid})
    end

    # Stubs Google's x509 endpoint. WebMock rather than Mocha on Faraday, so
    # the service's real HTTP + JSON + certificate parsing all run.
    def stub_certs(kid: DEFAULT_KID, pem: certificate_pem, max_age: 3600)
      WebMock.stub_request(:get, certs_url).to_return(
        status: 200,
        body: {kid => pem}.to_json,
        headers: {
          "Content-Type" => "application/json",
          "Cache-Control" => "public, max-age=#{max_age}, must-revalidate"
        }
      )
    end
  end
end
