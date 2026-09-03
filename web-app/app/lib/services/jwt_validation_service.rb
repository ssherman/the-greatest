# Service for validating Google/Firebase JWTs
require "jwt"
require "faraday"
require "json"
require "monitor"

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

    # Google's signing certificates rotate roughly daily, and every sign-in used
    # to fetch them synchronously -- making Google an availability dependency of
    # every login and adding a round trip to each one.
    #
    # In-process rather than Rails.cache on purpose: production configures no
    # cache_store, so Rails.cache is a per-container file store anyway, and this
    # avoids coupling authentication to any external store. Each process holds
    # its own copy; a few extra fetches across processes is not worth a
    # dependency.
    #
    # An unknown kid forces a refetch before it is treated as an error, so a key
    # rotation mid-cache-window recovers on the next request rather than failing
    # every sign-in until the window expires.
    CERT_CACHE_LOCK = Monitor.new
    DEFAULT_CERT_TTL = 3600

    def self.reset_cert_cache!
      CERT_CACHE_LOCK.synchronize do
        @certs = nil
        @certs_expire_at = nil
      end
    end

    def self.fetch_google_cert(kid)
      CERT_CACHE_LOCK.synchronize do
        load_certs! if @certs.nil? || @certs_expire_at.nil? || Time.current >= @certs_expire_at
        load_certs! unless @certs.key?(kid)

        cert_pem = @certs[kid]
        raise JWT::DecodeError, "Unknown key ID" unless cert_pem

        OpenSSL::X509::Certificate.new(cert_pem)
      end
    end

    def self.load_certs!
      response = Faraday.get(GOOGLE_CERTS_URL)

      unless response.success?
        raise JWT::DecodeError, "Failed to fetch Google certificates: #{response.status}"
      end

      @certs = JSON.parse(response.body)
      @certs_expire_at = Time.current + cache_ttl_from(response)
    end

    def self.cache_ttl_from(response)
      max_age = response.headers["cache-control"].to_s[/max-age=(\d+)/, 1]
      max_age ? max_age.to_i : DEFAULT_CERT_TTL
    end

    private_class_method :load_certs!, :cache_ttl_from
  end
end
