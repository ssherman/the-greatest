# 006 - User Model Implementation

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2025-01-27
- **Started**: 
- **Completed**: 
- **Developer**: 

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
*[This section will be filled out during/after implementation]*

### Approach Taken

### Key Files Changed

### Challenges Encountered

### Deviations from Plan

### Code Examples

### Testing Approach

### Performance Considerations

### Future Improvements

### Lessons Learned

### Related PRs

### Documentation Updated 