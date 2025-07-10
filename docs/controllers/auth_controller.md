# AuthController

## Summary
Handles user authentication endpoints for Firebase-based authentication. Provides sign-in and sign-out functionality across all domains (books, music, movies, games) with JWT token validation and session management.

## Public Methods

### `#sign_in`
Authenticates a user using a JWT token from Firebase and creates a Rails session.
- **Parameters:**
  - `jwt` (String) - Firebase JWT token
  - `provider` (String) - Authentication provider (google, facebook, etc.)
- **Returns:** JSON response with success status and user data
- **Side Effects:** Creates Rails session with user_id and provider
- **Status Codes:**
  - 200: Successful authentication
  - 401: Invalid credentials or missing parameters
  - 500: Internal server error

### `#sign_out`
Clears the user's authentication session.
- **Parameters:** None
- **Returns:** JSON response with success status
- **Side Effects:** Clears Rails session (user_id and provider)
- **Status Code:** 200: Successful sign out

## Validations
- JWT token presence and format (handled by JwtValidationService)
- Provider parameter presence
- User existence and validity (handled by UserAuthenticationService)

## Dependencies
- `AuthenticationService` - Main authentication orchestrator
- `JwtValidationService` - JWT token validation
- `UserAuthenticationService` - User creation/update logic
- Rails session management

## Security Considerations
- CSRF protection disabled for authentication endpoints (skip_before_action :verify_authenticity_token)
- JWT tokens validated against Google's public certificates
- Session-based authentication with secure cookie handling
- Error messages don't leak sensitive information

## Error Handling
- Graceful handling of missing parameters (returns 401)
- Comprehensive exception handling with logging
- User-friendly error messages in JSON responses
- Proper HTTP status codes for different error types

## Usage Examples

### Successful Sign In
```javascript
// Frontend JavaScript
fetch('/auth/sign_in', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jwt: 'firebase.jwt.token',
    provider: 'google'
  })
})
```

### Response Format
```json
{
  "success": true,
  "user": {
    "id": 123,
    "email": "user@example.com",
    "name": "John Doe",
    "provider": "google"
  }
}
```

## Cross-Domain Considerations
- Sessions are domain-specific by default
- For true SSO across domains, consider cookie domain configuration
- Firebase handles cross-domain authentication tokens
- User database is shared across all domains 