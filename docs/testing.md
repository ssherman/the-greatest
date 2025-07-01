# The Greatest - Testing Guide

## Core Testing Philosophy
- **Framework**: Minitest with fixtures
- **Mocking**: Mocha for stubs and mocks
- **Coverage Goal**: 100% test coverage
- **Scope**: Test public methods only - never test private methods

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
- All fixtures must use UUIDs for primary keys
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