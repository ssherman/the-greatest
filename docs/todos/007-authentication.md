# 007 - Firebase Authentication Implementation

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-07-08
- **Started**: 
- **Completed**: 
- **Developer**: 

## Overview
Implement a modular, multi-domain Firebase authentication system for The Greatest platform. This will replace the existing hacky authentication implementation with a clean, maintainable solution that works across all domains (books, music, movies, games) while sharing user data.

## Context
The current authentication system from The Greatest Books is functional but poorly structured:
- Monolithic authentication.js file loaded on every request
- Hardcoded domain-specific logic
- Poor separation of concerns
- Difficult to maintain and extend
- Not designed for multi-domain architecture

The new system needs to:
- Support all Firebase auth providers (email/password, Google, Facebook, Twitter, Apple, phone)
- Work seamlessly across multiple domains
- Use modern Rails patterns (ViewComponents, Stimulus)
- Follow the project's domain-driven design principles
- Be easily testable and maintainable

## Requirements
- [ ] Firebase SDK integration with proper domain detection
- [ ] Modular authentication service objects
- [ ] ViewComponent-based login widget
- [ ] Stimulus controller for client-side auth handling
- [ ] Multi-domain session management
- [ ] JWT token validation service
- [ ] User model enhancements for auth data
- [ ] Comprehensive test coverage
- [ ] Error handling and user feedback
- [ ] Security best practices implementation
- [ ] Email-only (passwordless) authentication support
- [ ] Redirect-only authentication flows (no popups)
- [ ] Caddy proxy configuration for Firebase auth endpoints
- [ ] Email confirmation system for email/password registration
- [ ] SendGrid integration for transactional emails
- [ ] Email confirmation token generation and validation

## Technical Approach

### Architecture Overview
```
Frontend (Stimulus + ViewComponent)
├── AuthenticationWidget (ViewComponent)
├── AuthenticationController (Stimulus)
└── FirebaseAuthService (JavaScript)
    ├── RedirectHandler (redirect-only flows)
    └── AuthProviders
        ├── EmailProvider (password + passwordless)
        ├── GoogleProvider
        ├── FacebookProvider
        ├── TwitterProvider
        └── AppleProvider

Backend (Rails Services)
├── AuthenticationService
├── JwtValidationService
├── UserAuthenticationService
├── SessionManagementService
├── EmailConfirmationService
└── SendGridService

Infrastructure
└── Caddy Proxy (Firebase auth endpoints)
```

### Key Design Decisions

1. **Service Object Pattern**: All authentication logic in service objects following the project's "Skinny Models, Fat Services" principle

2. **Domain-Aware Configuration**: Firebase config and auth endpoints adapt to current domain

3. **Modular JavaScript**: Separate modules for different auth providers and core functionality

4. **ViewComponent Integration**: Reusable login widget that works across all domains

5. **Stimulus for Interactivity**: Progressive enhancement with minimal JavaScript

6. **Redirect-Only Authentication**: All OAuth flows use redirects to avoid mobile popup issues

7. **Passwordless Email Support**: Email-only authentication using Firebase's email link feature

8. **Infrastructure Integration**: Caddy proxy configuration for Firebase auth endpoints

### File Structure
```
app/
├── components/
│   └── authentication/
│       ├── widget_component.rb
│       └── widget_component.html.erb
├── javascript/
│   ├── controllers/
│   │   └── authentication_controller.js
│   └── services/
│       ├── firebase_auth_service.js
│       ├── auth_providers/
│       │   ├── google_provider.js
│       │   ├── facebook_provider.js
│       │   ├── twitter_provider.js
│       │   ├── apple_provider.js
│       │   └── email_provider.js (password + passwordless)
│       └── auth_handlers/
│           └── redirect_handler.js
├── services/
│   ├── authentication_service.rb
│   ├── jwt_validation_service.rb
│   ├── user_authentication_service.rb
│   ├── session_management_service.rb
│   ├── email_confirmation_service.rb
│   └── sendgrid_service.rb
├── controllers/
│   └── authentication_controller.rb
└── models/
    └── user.rb (enhanced)
```

## Dependencies
- Firebase JavaScript SDK
- JWT gem for token validation
- Faraday gem for HTTP requests
- SendGrid gem for email confirmation
- ViewComponent gem (already available)
- Stimulus (already available)

## Infrastructure Requirements
- Caddy proxy configuration for Firebase auth endpoints:
  ```
  # Required for Firebase Authentication
  handle /__/auth/* {
    reverse_proxy https://the-greatest-books.firebaseapp.com
  }
  ```
- Firebase project with multiple authorized domains configured
- SSL certificates for all domains

## Acceptance Criteria
- [ ] Users can sign in with email/password on any domain
- [ ] Users can sign in with email-only (passwordless) on any domain
- [ ] Users can sign in with Google, Facebook, Twitter, Apple on any domain
- [ ] All OAuth flows use redirects (no popups)
- [ ] Email/password registrations require email confirmation
- [ ] Email confirmation tokens are secure and time-limited
- [ ] User sessions are shared across all domains
- [ ] JWT tokens are properly validated
- [ ] Authentication state is properly managed
- [ ] Error messages are user-friendly
- [ ] Login widget works consistently across all domains
- [ ] All authentication flows are tested
- [ ] Performance is optimized (no unnecessary requests)
- [ ] Security best practices are followed
- [ ] Caddy proxy correctly routes Firebase auth endpoints

## Implementation Plan

### Phase 1: Backend Foundation
1. **Enhance User Model**
   - Add missing auth-related fields
   - Improve validations and associations
   - Add auth-related methods
   - Add email confirmation fields (confirmed_at, confirmation_token, etc.)

2. **Create Service Objects**
   - `AuthenticationService` - Main orchestrator
   - `JwtValidationService` - Token validation logic
   - `UserAuthenticationService` - User creation/update logic
   - `SessionManagementService` - Session handling
   - `EmailConfirmationService` - Email confirmation logic
   - `SendGridService` - Email delivery service

3. **Create Authentication Controller**
   - Clean, RESTful endpoints
   - Proper error handling
   - Security headers
   - Email confirmation endpoints

### Phase 2: Frontend Foundation
1. **Install Firebase SDK**
   - Add to package.json
   - Configure for multi-domain

2. **Create JavaScript Services**
   - `FirebaseAuthService` - Core Firebase integration
   - Provider-specific modules (including passwordless email)
   - Redirect-only auth handlers
   - Auth state management

3. **Create Stimulus Controller**
   - Event handling
   - UI state management
   - Error display

### Phase 3: UI Components
1. **Create ViewComponent**
   - Login widget with all providers (including passwordless email)
   - Responsive design
   - Error states

2. **Integration**
   - Add to navigation across domains
   - Test all flows
   - Performance optimization

### Phase 4: Infrastructure
1. **Caddy Configuration**
   - Add Firebase auth endpoint proxy rules
   - Test proxy routing
   - Verify multi-domain support

### Phase 5: Testing & Polish
1. **Comprehensive Testing**
   - Unit tests for all services
   - Integration tests for auth flows
   - System tests for user journeys
   - Passwordless email flow testing
   - Email confirmation flow testing

2. **Security Review**
   - Token validation
   - CSRF protection
   - Rate limiting
   - Email link security
   - Email confirmation token security

3. **Performance Optimization**
   - Bundle size optimization
   - Caching strategies
   - Loading states

## Design Decisions

### Multi-Domain Strategy
- Single Firebase project with multiple authorized domains
- Domain-specific configuration loaded dynamically
- Shared user database across all domains
- Consistent auth experience
- Caddy proxy routes Firebase auth endpoints for all domains

### Email Confirmation Strategy
- **Email/Password Registration**: Requires email confirmation before account activation
- **OAuth Providers**: No email confirmation required (handled by provider)
- **Passwordless Email**: No additional confirmation (Firebase handles verification)
- **Confirmation Flow**: 
  - User registers with email/password
  - System generates secure confirmation token
  - SendGrid sends confirmation email with token
  - User clicks link to confirm email
  - Account activated and user can sign in
- **Grace Period**: Users can attempt to sign in but will be prompted to confirm email
- **Token Security**: Time-limited (24 hours), cryptographically secure tokens
- **Rate Limiting**: Prevent abuse of confirmation email sending

### Error Handling
- Structured error responses
- User-friendly error messages
- Proper logging for debugging
- Graceful degradation

### Security Considerations
- JWT token validation with proper key rotation
- CSRF protection on all auth endpoints
- Rate limiting on auth attempts
- Secure session management
- Email link expiration and validation
- Redirect URL validation for OAuth flows
- Email confirmation token security (time-limited, cryptographically secure)
- Email confirmation rate limiting to prevent abuse

### Performance Considerations
- Lazy loading of Firebase SDK
- Minimal JavaScript bundle size
- Efficient token caching
- Optimized re-renders

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