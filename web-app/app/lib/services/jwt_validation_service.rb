# Service for validating Google/Firebase JWTs
require "jwt"
require "faraday"
require "json"

module Services
  class JwtValidationService
    GOOGLE_CERTS_URL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"
    ALGORITHM = "RS256"

    # project_id is REQUIRED and deliberately has no default. Its `nil` default
    # was the vulnerability: AuthController never passed one, so the audience
    # check below was unreachable and a token from any Firebase project
    # validated here. A required argument makes that class of mistake a boot-time
    # ArgumentError instead of a silent hole.
    def self.call(token, project_id:)
      raise ArgumentError, "project_id is required" if project_id.blank?

      header = JWT.decode(token, nil, false).last
      cert = fetch_google_cert(header["kid"])

      # verify_aud/verify_iss are what actually enable the checks. Passing
      # `aud:` alone (as this did) configures a value ruby-jwt never compares.
      # ALGORITHM is a constant and is never read from the token header, which
      # is what makes an alg=none or algorithm-confusion forgery fail here.
      payload, _header = JWT.decode(token, cert.public_key, true, {
        algorithm: ALGORITHM,
        aud: project_id,
        verify_aud: true,
        iss: "https://securetoken.google.com/#{project_id}",
        verify_iss: true,
        verify_expiration: true,
        verify_iat: true
      })

      # Firebase guarantees a non-empty sub; a token without one identifies
      # nobody, and every lookup downstream keys on it.
      raise JWT::DecodeError, "Token has no subject" if payload["sub"].blank?

      payload
    end

    def self.fetch_google_cert(kid)
      response = Faraday.get(GOOGLE_CERTS_URL)

      unless response.success?
        raise JWT::DecodeError, "Failed to fetch Google certificates: #{response.status}"
      end

      certs = JSON.parse(response.body)
      cert_pem = certs[kid]
      raise JWT::DecodeError, "Unknown key ID" unless cert_pem

      OpenSSL::X509::Certificate.new(cert_pem)
    end
  end
end
