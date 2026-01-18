# User

## Summary
Represents a user of The Greatest platform. Handles authentication, roles, and user profile information. Shared across all media domains (books, movies, music, games).

## Associations
- `has_many :lists, foreign_key: :submitted_by_id` - Lists submitted by this user (optional, inverse of List#submitted_by)
- `has_many :domain_roles, dependent: :destroy` - Domain-scoped permissions for admin access

## Public Methods

### `#domain_role_for(domain)`
Gets the user's DomainRole for a specific domain.
- Parameters: domain (String) - Domain name ("music", "games", "books", "movies")
- Returns: DomainRole or nil

### `#can_access_domain?(domain)`
Checks if user can access a domain's admin area.
- Parameters: domain (String)
- Returns: Boolean (true if admin or has domain role)

### `#can_read_in_domain?(domain)`
Checks if user has read access in a domain.
- Parameters: domain (String)
- Returns: Boolean

### `#can_write_in_domain?(domain)`
Checks if user has write access in a domain.
- Parameters: domain (String)
- Returns: Boolean

### `#can_delete_in_domain?(domain)`
Checks if user has delete access in a domain.
- Parameters: domain (String)
- Returns: Boolean

### `#can_manage_domain?(domain)`
Checks if user has manage access in a domain.
- Parameters: domain (String)
- Returns: Boolean

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

# Domain-scoped permissions
user.domain_roles.create!(domain: :music, permission_level: :editor)
user.can_access_domain?("music")  # => true
user.can_write_in_domain?("music")  # => true
user.can_delete_in_domain?("music")  # => false (editor can't delete)

# Set external provider
user.external_provider = :google
user.save!

# Serialize provider data
user.provider_data = { provider_id: "123", name: "John" }
user.save!
``` 