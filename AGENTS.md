# AGENTS.md - The Greatest

AI agents working on this project should follow these guidelines for optimal development workflow.

## Project Overview

The Greatest is a multi-domain Rails application serving separate sites for books, music, movies, and games from a single codebase. The Rails application is located in the `web-app/` directory.

**Key Architecture:**
- Single Rails 8 app serving multiple domains (thegreatestbooks.org, thegreatestmusic.org, etc.)
- Domain-specific namespacing for all media types (Books::, Movies::, Games::, Music::)
- Polymorphic associations for shared functionality (reviews, lists, rankings)
- Rollup-based build system with domain-specific bundles

## Working Directory

**CRITICAL:** All Rails commands must be run from the `web-app/` directory:

```bash
cd web-app
bundle install
bin/rails server
bin/rails test
bin/rails generate model Books::Book title:string
```

## Core Development Principles

### 1. Namespacing Requirements
- All media-specific code MUST be namespaced: `Books::Book`, `Movies::Director`, `Games::Platform`
- Shared models (User, List, Review) remain in global namespace
- Service objects follow same pattern: `Books::ImportService`, `Movies::MetadataService`

### 2. Database Design
- Use polymorphic associations for shared functionality:
  ```ruby
  belongs_to :reviewable, polymorphic: true
  belongs_to :listable, polymorphic: true
  ```
- Always use `_able` suffix for polymorphic associations
- FriendlyId required for all user-facing resources

### 3. Rails 8 Syntax
- **CRITICAL:** Use new enum syntax with colon prefix:
  ```ruby
  # ✅ Correct
  enum :status, { active: 0, inactive: 1 }
  
  # ❌ Wrong (will cause errors)
  enum status: { active: 0, inactive: 1 }
  ```

### 4. Service Pattern
All business logic goes in service objects with consistent Result pattern:
```ruby
class ApplicationService
  Result = Struct.new(:success?, :data, :errors, keyword_init: true)
  
  def self.call(...)
    new(...).call
  end
end
```

## Testing Requirements

### Framework & Standards
- **Framework:** Minitest with fixtures (NOT RSpec)
- **Coverage:** 100% required
- **Scope:** Test public methods only, never private methods
- **Mocking:** Use Mocha for external services

### Critical Testing Rules
1. **Always check fixture names:** Never assume `users(:one)` exists - check `test/fixtures/users.yml` for actual names
2. **Polymorphic fixtures:** Use correct syntax:
   ```yaml
   # ✅ Correct
   review:
     reviewable: dark_side_moon (Music::Album)
   
   # ❌ Wrong
   review:
     reviewable: dark_side_moon
     reviewable_type: Music::Album
   ```
3. **Namespace test classes:** Media-specific tests must be namespaced to match models

### Test Commands
```bash
cd web-app
bin/rails test                    # Run all tests
bin/rails test:models            # Models only
bin/rails test test/models/books/ # Books namespace only
```

## DataImporter System

### Key Architecture Changes (2025-09-15)
- **Incremental saving**: Items saved after each successful provider (enables background jobs)
- **Force providers**: Use `force_providers: true` to re-enrich existing items
- **Background job ready**: Async providers can launch Sidekiq jobs and return success immediately

### Usage Examples
```ruby
# Basic import
DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

# Re-enrich existing item with new providers
DataImporters::Music::Artist::Importer.call(name: "Pink Floyd", force_providers: true)

# Async provider pattern (for future Amazon API integration)
class Providers::SlowAPI < ProviderBase
  def populate(item, query:)
    SlowEnrichmentJob.perform_async(item.id, query.to_h)
    ProviderResult.new(success: true, provider_name: self.class.name)
  end
end

# CRITICAL: Always use find_or_initialize_by for identifiers
item.identifiers.find_or_initialize_by(
  identifier_type: :music_musicbrainz_artist_id,
  value: external_id
)
# Never use build() as it creates duplicates on provider re-runs
```

## Code Quality

### Required Commands Before Committing
Always run these from `web-app/` directory:
```bash
bin/rails test        # All tests must pass
# Note: Check if lint/typecheck commands exist in package.json or Gemfile
```

### Code Style
- **No comments** unless explicitly requested
- Self-documenting code with clear naming
- Follow existing patterns in codebase
- Use Rails conventions and built-in tools first

## File Structure

```
web-app/                 # Rails application root
├── app/
│   ├── models/
│   │   ├── books/      # Books::Book, Books::Author
│   │   ├── movies/     # Movies::Movie, Movies::Director  
│   │   └── user.rb     # Shared models in root
│   └── services/
│       ├── books/      # Books::ImportService
│       └── shared/     # Cross-domain services
├── test/
│   ├── fixtures/
│   │   ├── books/
│   │   └── users.yml   # Shared fixtures
│   └── models/
│       └── books/      # module Books; class BookTest
└── docs/               # All documentation (NOT in web-app/)
    ├── models/         # Class documentation
    ├── features/       # Feature overviews
    └── todos/          # Task management
```

## Documentation Requirements

### Class Documentation
Every model/service needs corresponding documentation in `docs/`:
- `docs/models/books/book.md` for `Books::Book`
- Include associations, public methods, validations, scopes
- **Always document associations to result tables** (ranked_items, ranked_lists)

### Task Management
Use `docs/todo.md` and `docs/todos/` for planning:
- Break complex tasks into smaller files
- Document decisions and implementation notes
- Include acceptance criteria and dependencies

## Multi-Domain Considerations

### Request Handling
- Early host detection determines current domain
- Domain-specific layouts and assets
- Separate Rollup bundles per domain

### Development Setup
Test different domains locally using `/etc/hosts` or similar.

## Security & Performance

### Security Rules
- Never commit secrets or API keys
- Use strong parameters everywhere
- Firebase Auth for authentication
- Simple role-based authorization

### Performance Requirements
- Sub-second page loads required
- Use `includes`/`preload` to prevent N+1 queries
- Russian doll caching strategy
- Background jobs via Sidekiq with domain-specific queues

## External Integrations

### APIs & Services
- OpenSearch for full-text search
- Firebase Authentication
- Multiple AI APIs (ChatGPT, Claude, Google AI)
- Various media APIs (MusicBrainz, TMDB, etc.)

### Always Mock External Services
Never make real API calls in tests - stub all external dependencies.

## Common Pitfalls

1. **Wrong working directory:** Always `cd web-app/` first
2. **Fixture references:** Check actual fixture names before using
3. **Enum syntax:** Use Rails 8 format with colon prefix
4. **Namespacing:** Media-specific code must be namespaced
5. **Documentation location:** All docs go in top-level `docs/`, not `web-app/docs/`

## Related Documentation

For deeper context, see:
- [`docs/dev-core-values.md`](docs/dev-core-values.md) - Complete development principles
- [`docs/summary.md`](docs/summary.md) - Project architecture and goals
- [`docs/documentation.md`](docs/documentation.md) - Documentation standards
- [`docs/testing.md`](docs/testing.md) - Comprehensive testing guide
- [`docs/todo-guide.md`](docs/todo-guide.md) - Task management workflow

## Quick Start Checklist

1. `cd web-app/`
2. `bundle install`
3. Check existing code patterns before implementing
4. Follow namespacing rules for media-specific code
5. Use Rails 8 enum syntax
6. Write tests with proper fixture references
7. Run `bin/rails test` before committing
8. Update relevant documentation in `docs/`