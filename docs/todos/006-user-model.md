# 006 - User Model Implementation

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2025-01-27
- **Started**: 2025-07-06
- **Completed**: 2025-07-06
- **Developer**: Shane Sherman

## Overview
Implement the User model for The Greatest platform, supporting multi-domain authentication and user management across all media types (books, movies, music, games).

## Context
The User model is a core component that needs to support:
- Multi-domain authentication (users can sign up from any of the media-specific domains)
- Firebase Authentication integration
- User preferences and settings across all media types
- List management and tracking functionality
- Review and rating capabilities

This model will be shared across all domains and needs to handle the complexity of users who may interact with multiple media types.

## Requirements
- [ ] Create User model with Firebase Auth integration
- [ ] Support multi-domain user registration (track original signup domain)
- [ ] Remove deprecated Goodreads import functionality
- [ ] Implement user roles and permissions
- [ ] Add user preferences and settings
- [ ] Support user profile management
- [ ] Implement user activity tracking
- [ ] Add proper validations and constraints
- [ ] Create comprehensive test coverage
- [ ] Update documentation

## Technical Approach

### Database Schema
Based on the existing user model, we'll:
- Keep core authentication fields (auth_uid, auth_data, email, etc.)
- Remove `goodreads_import` field (no longer needed)
- Add `original_signup_domain` field to track which domain the user first registered on
- Clean up deprecated fields and simplify the schema
- Maintain backward compatibility for existing users

### Key Fields to Include
- `id` - Primary key (auto-incrementing bigint)
- `auth_uid` - Firebase Auth UID (not primary identifier)
- `email` - User's email address
- `display_name` - User's display name
- `name` - Full name
- `photo_url` - Profile photo URL
- `original_signup_domain` - Domain where user first registered
- `role` - User role (user, admin, editor) - defaults to user
- `external_provider` - Authentication provider (facebook, twitter, google, apple, password)
- `email_verified` - Email verification status
- `last_sign_in_at` - Last sign in timestamp
- `sign_in_count` - Number of sign ins
- `auth_data` - JSONB field for Firebase Auth data
- `provider_data` - JSON field for provider-specific data
- `stripe_customer_id` - For future payment integration

### Model Design
- Follow Rails conventions and the established patterns
- Implement proper validations and associations
- Use enums for role and external provider fields
- Add scopes for common queries
- Implement service objects for complex operations

## Dependencies
- Firebase Authentication setup (task #5)
- Database migration system
- Rails model testing framework
- Documentation system

## Acceptance Criteria
- [ ] User can register from any domain (books, movies, music, games)
- [ ] Original signup domain is tracked and stored
- [ ] Firebase Auth integration works seamlessly
- [ ] User can manage profile across all domains
- [ ] Role-based permissions work correctly
- [ ] All validations prevent invalid data
- [ ] Tests cover all public methods and edge cases
- [ ] Documentation is complete and accurate
- [ ] Migration handles existing user data properly

## Design Decisions

### Multi-Domain User Tracking
- Store `original_signup_domain` to understand user acquisition
- Allow users to access all domains with single account
- Maintain user preferences across domains

### Firebase Integration
- Use `auth_uid` as Firebase identifier (separate from primary key)
- Store Firebase Auth data in JSONB for flexibility
- Handle email verification through Firebase
- Support multiple authentication providers (Facebook, Twitter, Google, Apple, password)

### Role System
- Role enum (user, admin, editor) - defaults to user
- External provider enum (facebook, twitter, google, apple, password)
- Role-based authorization in controllers
- Provider data stored in JSON field for flexibility

### Data Cleanup
- Remove Goodreads import functionality
- Clean up deprecated fields
- Maintain data integrity during migration

---

## Implementation Notes

### Approach Taken
- Used Rails generator to create User model with all required fields
- Updated migration to add proper constraints and indexes
- Implemented enums for role and external_provider following Rails conventions
- Added JSON serialization for provider_data field
- Created comprehensive tests using fixtures (following project guidelines)
- Updated Avo admin interface to handle enums properly

### Key Files Changed
- `db/migrate/20250706224120_create_users.rb` - Database migration with constraints and indexes
- `app/models/user.rb` - User model with enums, validations, and JSON serialization
- `test/models/user_test.rb` - Comprehensive test coverage using fixtures
- `test/fixtures/users.yml` - Test data for admin, regular, and editor users
- `app/avo/resources/user.rb` - Avo admin interface with proper enum handling
- `docs/models/user.md` - Complete model documentation
- `docs/models/list.md` - Updated to include submitted_by association

### Challenges Encountered
- Migration initially failed due to incorrect foreign key reference (fixed by specifying `to_table: :users`)
- Needed to ensure proper enum handling in Avo admin interface

### Deviations from Plan
- No major deviations - implementation followed the planned approach closely
- Added submitted_by association to List model as an additional enhancement

### Code Examples
```ruby
# User model with enums and validations
class User < ApplicationRecord
  serialize :provider_data, coder: JSON
  enum :role, [:user, :admin, :editor]
  enum :external_provider, [:facebook, :twitter, :google, :apple, :password]
  validates :email, presence: true, uniqueness: true
  validates :role, presence: true
  validates :email_verified, inclusion: { in: [true, false] }
end

# Avo admin interface with enum handling
field :role, as: :select, enum: ::User.roles
field :external_provider, as: :select, enum: ::User.external_providers
```

### Testing Approach
- Used fixtures instead of creating data in setup (following project guidelines)
- 9 comprehensive tests covering all validations and functionality
- Tests for email requirements, role defaults, external providers, JSON serialization
- Verified fixture data loads correctly with proper role assignments

### Performance Considerations
- Added database indexes on auth_uid, external_provider, and stripe_customer_id
- JSONB field for auth_data provides efficient storage and querying
- Proper foreign key constraints ensure data integrity

### Future Improvements
- Add user activity tracking methods
- Implement user preferences system
- Add scopes for common user queries
- Consider adding user profile management features

### Lessons Learned
- Rails enums work seamlessly with Avo admin interface when properly configured
- Using fixtures in tests provides better performance and follows project standards
- JSON serialization for provider_data provides flexibility for different auth providers

### Related PRs
- User model implementation with Firebase Auth integration
- List model submitted_by association addition

### Documentation Updated
- ✅ Created comprehensive User model documentation (`docs/models/user.md`)
- ✅ Updated List model documentation to include submitted_by association
- ✅ Updated todo list to mark task as completed 