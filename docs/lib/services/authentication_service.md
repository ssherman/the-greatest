# AuthenticationService

## Summary
Main authentication orchestrator that coordinates JWT validation, user authentication, and user creation/update. Acts as the primary entry point for all Firebase-based authentication flows across the multi-domain platform.

## Public Methods

### `.call(auth_token:, provider:, project_id: nil)`
Main authentication method that validates JWT tokens and finds or creates users.
- **Parameters:**
  - `auth_token` (String) - Firebase JWT token to validate
  - `provider` (String) - Authentication provider (google, facebook, twitter, apple, email)
  - `project_id` (String, optional) - Firebase project ID for audience validation
- **Returns:** Hash with authentication result
  - Success: `{ success: true, user: User, provider_data: Hash }`
  - Failure: `{ success: false, error: String, error_code: Symbol }`
- **Side Effects:** May create or update user records in database

## Error Handling
The service handles several types of errors and returns appropriate error codes:

### JWT::DecodeError
- **Error Code:** `:invalid_token`
- **Message:** "Invalid authentication token"
- **Cause:** Malformed or invalid JWT token

### ActiveRecord::RecordInvalid
- **Error Code:** `:user_creation_failed`
- **Message:** "Failed to create user account"
- **Cause:** User validation failures during creation/update

### StandardError
- **Error Code:** `:authentication_failed`
- **Message:** "Authentication failed"
- **Cause:** Any other unexpected errors

## Dependencies
- `JwtValidationService` - Validates JWT tokens against Google's public certificates
- `UserAuthenticationService` - Handles user creation and updates
- `User` model - Database operations
- `JWT` gem - Token decoding and validation
- `Faraday` gem - HTTP requests for certificate fetching

## Private Methods

### `.extract_provider_data(payload, provider)`
Extracts standardized user data from JWT payload for user creation/update.
- **Parameters:**
  - `payload` (Hash) - Decoded JWT payload
  - `provider` (String) - Authentication provider
- **Returns:** Hash with standardized provider data
- **Extracted Fields:**
  - `user_id` - Firebase user ID (sub claim)
  - `email` - User's email address
  - `name` - User's display name
  - `picture` - Profile picture URL
  - `email_verified` - Email verification status
  - `provider` - Authentication provider
  - `auth_time` - Authentication timestamp
  - `iat` - Token issued at timestamp
  - `exp` - Token expiration timestamp

## Constants
- `ALGORITHM` - JWT algorithm (RS256)
- `GOOGLE_CERTS_URL` - Google's public certificate endpoint

## Usage Examples

### Successful Authentication
```ruby
result = AuthenticationService.call(
  auth_token: "firebase.jwt.token",
  provider: "google"
)

if result[:success]
  user = result[:user]
  # User is authenticated and available
else
  error = result[:error]
  # Handle authentication failure
end
```

### With Project ID Validation
```ruby
result = AuthenticationService.call(
  auth_token: "firebase.jwt.token",
  provider: "google",
  project_id: "my-firebase-project"
)
```

## Security Features
- JWT validation against Google's public certificates
- Optional Firebase project ID validation (audience claim)
- Secure token decoding with proper algorithm verification
- Comprehensive error logging for debugging
- No sensitive data exposure in error messages

## Multi-Domain Support
- Works across all domains (books, music, movies, games)
- Shared user database ensures consistent user experience
- Provider data stored per authentication method
- Supports multiple authentication providers per user 