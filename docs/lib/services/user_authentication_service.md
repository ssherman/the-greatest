# UserAuthenticationService

## Summary
Service responsible for finding existing users or creating new users from authentication provider data. Handles user record management, provider data storage, and sign-in statistics across the multi-domain platform.

## Public Methods

### `.call(provider_data:)`
Finds or creates a user based on provider authentication data.
- **Parameters:**
  - `provider_data` (Hash) - Standardized provider data containing user information
- **Returns:** User instance (newly created or updated)
- **Side Effects:** Creates or updates user record, increments sign-in count
- **Raises:** ArgumentError if provider is missing, ActiveRecord::RecordInvalid for validation failures

## Provider Data Requirements
The service expects a hash with the following keys:
- `email` (String) - User's email address
- `user_id` (String) - Firebase user ID (sub claim)
- `name` (String) - User's display name
- `picture` (String) - Profile picture URL
- `provider` (String) - Authentication provider (required)
- `email_verified` (Boolean) - Email verification status

## User Lookup Strategy
1. **Primary Lookup:** Find by email (case-insensitive)
2. **Fallback Lookup:** Find by auth_uid (Firebase user ID)
3. **Create New:** If no user found, create new user record

## User Creation Logic
When creating a new user:
- Sets email, auth_uid, display_name, photo_url
- Sets external_provider to the authentication provider
- Sets email_verified based on provider data
- Sets role to :user (default)
- Sets last_sign_in_at to current time
- Sets sign_in_count to 1

## User Update Logic
When updating an existing user:
- Updates auth_uid, display_name, photo_url
- Updates external_provider
- Updates email_verified (only if provider indicates verified)
- Updates last_sign_in_at to current time
- Increments sign_in_count

## Provider Data Storage
- Stores complete provider data in user.provider_data hash
- Uses provider name as key (e.g., "google", "facebook")
- Preserves historical authentication data
- Allows multiple providers per user

## Error Handling
- **ArgumentError:** Raised if provider is missing from provider_data
- **ActiveRecord::RecordInvalid:** Raised for validation failures during save
- **Logging:** All errors are logged with detailed messages

## Dependencies
- `User` model - Database operations and validations
- `ActiveRecord` - Database transaction handling
- Rails logging system for error reporting

## Usage Examples

### Basic Usage
```ruby
provider_data = {
  email: "user@example.com",
  user_id: "firebase_uid_123",
  name: "John Doe",
  picture: "https://example.com/photo.jpg",
  provider: "google",
  email_verified: true
}

user = UserAuthenticationService.call(provider_data: provider_data)
```

### Handling Errors
```ruby
begin
  user = UserAuthenticationService.call(provider_data: provider_data)
  # User found or created successfully
rescue ArgumentError => e
  # Missing required provider data
rescue ActiveRecord::RecordInvalid => e
  # User validation failed
end
```

## Database Fields Updated
- `email` - User's email address (only on creation)
- `auth_uid` - Firebase user ID
- `display_name` - User's display name
- `photo_url` - Profile picture URL
- `external_provider` - Current authentication provider
- `email_verified` - Email verification status
- `last_sign_in_at` - Timestamp of last sign-in
- `sign_in_count` - Total number of sign-ins
- `provider_data` - JSON hash of provider-specific data

## Multi-Domain Considerations
- Works across all domains (books, music, movies, games)
- User records are shared across domains
- Provider data is domain-agnostic
- Sign-in statistics are global per user

## Security Features
- Case-insensitive email matching prevents duplicate accounts
- Provider data validation prevents invalid data storage
- Comprehensive error logging for debugging
- No sensitive data exposure in error messages 