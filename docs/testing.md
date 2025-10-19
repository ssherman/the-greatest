# The Greatest - Testing Guide

## Core Testing Philosophy
- **Framework**: Minitest with fixtures
- **Mocking**: Mocha for stubs and mocks
- **Coverage Goal**: 100% test coverage
- **Scope**: Test public methods only - never test private methods

## Fixture Best Practices and Common Pitfalls

### Always Check Actual Fixture Names
A common source of test failures is assuming fixture references like `user: one` or `users(:one)` exist, when the actual fixture names may be different (e.g., `regular_user`, `admin_user`).

**Best Practice:**
- Always check the relevant fixture file (e.g., `test/fixtures/users.yml`) for the correct keys before referencing them in tests or other fixtures.
- Never assume that `one`, `two`, etc. exist—use descriptive fixture names and reference them explicitly.
- If you add new fixtures, use clear, semantic names (e.g., `regular_user`, `editor_user`).

**Example (bad):**
```yaml
user_penalty:
  user: one  # ❌ This will fail if 'one' is not defined in users.yml
```

**Example (good):**
```yaml
user_penalty:
  user: regular_user  # ✅ Always use the actual fixture name
```

**AI/Automation Note:**
- When using AI agents or code generation, always instruct the agent to check the actual fixture file for valid keys before referencing them. This prevents a very common and frustrating class of test failures.

## Test Organization

### Namespacing Requirements
All media-specific tests MUST be namespaced in modules, matching the application structure:
```
test/
├── models/
│   ├── books/
│   │   └── book_test.rb         # module Books; class BookTest
│   ├── movies/
│   │   └── movie_test.rb        # module Movies; class MovieTest
│   ├── games/
│   │   └── game_test.rb         # module Games; class GameTest
│   ├── music/
│   │   └── album_test.rb        # module Music; class AlbumTest
│   └── user_test.rb             # class UserTest (not namespaced - shared model)
├── services/
│   ├── books/
│   │   └── import_service_test.rb
│   └── recommendation_service_test.rb
└── fixtures/
    ├── books/
    │   └── books.yml
    ├── movies/
    │   └── movies.yml
    └── users.yml
```

### Fixture Guidelines
- Use polymorphic associations correctly in fixtures
- Keep fixtures minimal but realistic
- Share common fixtures (users, reviews) across domains

### Testing Standards
- Test all public methods
- Never test private methods
- Use descriptive test names that explain the behavior
- One assertion per test when possible
- Setup common test data in `setup` method

### Mocking with Mocha
- Mock external API calls
- Stub time-sensitive methods
- Mock AI service responses
- Never mock what you don't own

### What NOT to Test (Common Mistakes)
- **Never test log statements at all** - Logging is an implementation detail, not behavior. Don't verify that logs are written.
  ```ruby
  # ❌ Bad - testing implementation details
  Rails.logger.expects(:info)
  Rails.logger.expects(:error).with("Failed to process")

  # ✅ Good - test the actual behavior
  # Just call the method and test what it does, not that it logs
  service.call
  assert result.success?
  ```
- **Never test exact error message strings** - Focus on behavior, not message content
- **Never test system message or prompt content for AI tasks** - These change frequently as prompts are refined
- **Never test private method implementation details** - Test public interface only
- **Never test specific validation error messages** - Test that validation fails, not the exact wording
- **Never write tests for Avo actions** - Avo actions are admin UI components that are manually tested. Writing automated tests for them is not necessary and adds maintenance burden.

### Multi-Domain Testing
- Test each domain's functionality in isolation
- Integration tests should verify cross-domain features
- Use `host!` to set the domain in integration tests
- System tests for critical user journeys per domain

### Performance Requirements
- Tests must run fast - use fixtures, not database creation
- Parallel test execution enabled by default
- No external network calls in tests
- Stub all third-party services

### CI Requirements
- 100% test coverage enforced
- All tests must pass before merge
- No skipped tests without documented reason
- Coverage reports generated on each run