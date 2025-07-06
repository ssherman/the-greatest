# User

## Summary
Represents a user of The Greatest platform. Handles authentication, roles, and user profile information. Shared across all media domains (books, movies, music, games).

## Associations
- `has_many :lists, foreign_key: :submitted_by_id` - Lists submitted by this user (optional, inverse of List#submitted_by)

## Public Methods
No custom public methods defined. Inherits standard ActiveRecord methods.

## Validations
- `email` - presence required, uniqueness required
- `role` - presence required, enum (user, admin, editor)
- `email_verified` - inclusion in [true, false]

## Enums
- `role` - [:user, :admin, :editor] (default: user)
- `external_provider` - [:facebook, :twitter, :google, :apple, :password]

## Constants
None defined.

## Callbacks
None defined.

## Dependencies
- JSON serialization for provider_data
- Enum functionality for roles and external providers

## Database Schema
- `id` - Primary key
- `auth_uid` - Firebase Auth UID (string)
- `auth_data` - Firebase Auth data (jsonb)
- `email` - User's email address (string, not null, unique)
- `display_name` - User's display name (string)
- `name` - Full name (string)
- `photo_url` - Profile photo URL (string)
- `original_signup_domain` - Domain where user first registered (string)
- `role` - User role (integer, not null, default: 0)
- `external_provider` - Authentication provider (integer)
- `email_verified` - Email verification status (boolean, not null, default: false)
- `last_sign_in_at` - Last sign in timestamp (datetime)
- `sign_in_count` - Number of sign ins (integer)
- `provider_data` - Provider-specific data (text, serialized as JSON)
- `stripe_customer_id` - Stripe customer ID (string)
- `created_at` - Creation timestamp
- `updated_at` - Update timestamp

## Usage Examples
```ruby
# Create a new user
user = User.create!(email: "user@example.com", display_name: "User", role: :user)

# Assign a user as the submitter of a list
list = List.create!(name: "User List", submitted_by: user, status: :approved)

# Query all lists submitted by a user
user.lists

# Check user role
user.admin?
user.editor?
user.user?

# Set external provider
user.external_provider = :google
user.save!

# Serialize provider data
user.provider_data = { provider_id: "123", name: "John" }
user.save!
``` 