# Service for validating Google/Firebase JWTs
require "jwt"
require "faraday"
require "json"

class JwtValidationService
  GOOGLE_CERTS_URL = "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com"
  ALGORITHM = "RS256"

  def self.call(token, project_id: nil)
    header = JWT.decode(token, nil, false).last
    kid = header["kid"]
    cert = fetch_google_cert(kid)
    payload, _ = JWT.decode(token, cert.public_key, true, {algorithm: ALGORITHM, aud: project_id})
    # Optionally validate project_id (aud claim)
    if project_id && payload["aud"] != project_id
      raise JWT::InvalidAudError, "Invalid audience: #{payload["aud"]}"
    end
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
