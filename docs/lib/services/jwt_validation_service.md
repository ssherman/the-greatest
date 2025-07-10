# JwtValidationService

## Summary
Service for validating Google/Firebase JWT tokens against Google's public certificates. Ensures token authenticity, expiration, and audience validation for secure authentication across the multi-domain platform.

## Public Methods

### `.call(token, project_id: nil)`
Validates a JWT token from Google/Firebase and returns the decoded payload.
- **Parameters:**
  - `token` (String) - JWT token to validate
  - `project_id` (String, optional) - Firebase project ID for audience validation
- **Returns:** Hash containing the decoded JWT payload
- **Raises:** JWT::DecodeError for invalid tokens, JWT::InvalidAudError for audience mismatch

## Validation Process
1. **Decode Header:** Extract key ID (kid) from token header
2. **Fetch Certificate:** Retrieve corresponding public certificate from Google
3. **Verify Token:** Validate signature, expiration, and audience
4. **Return Payload:** Return decoded claims if validation passes

## JWT Claims Validated
- **Signature:** Verified against Google's public certificates
- **Algorithm:** Must be RS256
- **Expiration:** Token must not be expired
- **Issued At:** Token must have valid issued timestamp
- **Audience:** Optional validation against Firebase project ID

## Constants
- `GOOGLE_CERTS_URL` - Google's public certificate endpoint
- `ALGORITHM` - Required JWT algorithm (RS256)

## Private Methods

### `.fetch_google_cert(kid)`
Fetches the public certificate for a specific key ID from Google's certificate endpoint.
- **Parameters:**
  - `kid` (String) - Key ID from JWT header
- **Returns:** OpenSSL::X509::Certificate instance
- **Raises:** JWT::DecodeError if certificate fetch fails or key ID not found

## Error Handling
The service handles several validation scenarios:

### JWT::DecodeError
- **Cause:** Invalid token format, expired token, or signature verification failure
- **Action:** Re-raises the error for upstream handling

### JWT::InvalidAudError
- **Cause:** Token audience doesn't match provided project_id
- **Action:** Re-raises the error for upstream handling

### HTTP Request Failures
- **Cause:** Network issues or Google service unavailability
- **Action:** Raises JWT::DecodeError with descriptive message

### Unknown Key ID
- **Cause:** Key ID not found in Google's certificate set
- **Action:** Raises JWT::DecodeError with "Unknown key ID" message

## Dependencies
- `JWT` gem - Token decoding and validation
- `Faraday` gem - HTTP requests to Google's certificate endpoint
- `OpenSSL` - Certificate handling and public key operations
- `JSON` - Certificate response parsing

## Usage Examples

### Basic Token Validation
```ruby
begin
  payload = JwtValidationService.call("firebase.jwt.token")
  # Token is valid, payload contains user claims
rescue JWT::DecodeError => e
  # Token is invalid or expired
end
```

### With Project ID Validation
```ruby
begin
  payload = JwtValidationService.call(
    "firebase.jwt.token",
    project_id: "my-firebase-project"
  )
  # Token is valid and audience matches
rescue JWT::InvalidAudError => e
  # Token audience doesn't match project ID
rescue JWT::DecodeError => e
  # Token is invalid for other reasons
end
```

### Accessing Token Claims
```ruby
payload = JwtValidationService.call(token)
user_id = payload['sub']           # Firebase user ID
email = payload['email']           # User's email
name = payload['name']             # User's name
picture = payload['picture']       # Profile picture URL
email_verified = payload['email_verified']  # Email verification status
auth_time = payload['auth_time']   # Authentication timestamp
```

## Security Features
- **Certificate Rotation:** Automatically fetches latest certificates from Google
- **Signature Verification:** Validates token signature against Google's public keys
- **Algorithm Enforcement:** Only accepts RS256 algorithm
- **Expiration Checking:** Validates token expiration timestamps
- **Audience Validation:** Optional Firebase project ID validation
- **Key ID Validation:** Ensures token uses valid certificate key

## Performance Considerations
- **Certificate Caching:** Consider implementing certificate caching for production
- **HTTP Timeouts:** Faraday requests may timeout on slow connections
- **Error Logging:** Failed validations are logged for debugging

## Firebase Integration
- Compatible with Firebase Authentication tokens
- Supports all Firebase auth providers (Google, Facebook, Twitter, Apple, etc.)
- Validates against Firebase's Google Cloud project certificates
- Handles Firebase's token format and claims structure

## Multi-Domain Support
- Works across all domains (books, music, movies, games)
- Token validation is domain-agnostic
- Supports Firebase project configuration per environment
- Consistent validation across all authentication flows 