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

## 🚨 FILE PATH CRITICAL REMINDER 🚨

**ALWAYS CHECK YOUR WORKING DIRECTORY FIRST WITH `pwd`**

Your working directory can be EITHER the project root OR the Rails web-app directory. The correct file paths depend on where you currently are.

### Project Structure
```
<project-root>/                          # Sometimes you are HERE
├── docs/                                # Documentation
│   ├── todo.md
│   ├── todos/
│   ├── models/
│   └── ...
├── AGENTS.md                            # This file
├── README.md
└── web-app/                             # Sometimes you are HERE
    ├── app/
    ├── config/
    ├── test/
    └── ...
```

### Step 1: Check Where You Are

**CRITICAL:** Before writing or reading files, always determine your working directory:

```bash
pwd
# Output: /home/shane/dev/the-greatest          → You are in PROJECT ROOT
# Output: /home/shane/dev/the-greatest/web-app  → You are in RAILS ROOT
```

### Step 2: Use Correct Paths Based on Location

#### If you are in PROJECT ROOT (`/home/shane/dev/the-greatest`)

```bash
# ✅ CORRECT - Documentation files (NO ../ prefix)
docs/todo.md
docs/todos/077-task.md
docs/models/music/song.md
AGENTS.md

# ✅ CORRECT - Rails files (use web-app/ prefix)
web-app/app/controllers/admin/music/songs_controller.rb
web-app/app/models/music/song.rb
web-app/config/routes.rb
web-app/test/controllers/admin/music/songs_controller_test.rb

# ❌ WRONG - Do not use ../ prefix when in project root
../docs/todo.md           # This goes OUTSIDE the project!
../docs/todos/077-task.md # This goes to parent directory!
```

#### If you are in RAILS ROOT (`/home/shane/dev/the-greatest/web-app`)

```bash
# ✅ CORRECT - Documentation files (use ../ prefix)
../docs/todo.md
../docs/todos/077-task.md
../docs/models/music/song.md
../AGENTS.md

# ✅ CORRECT - Rails files (NO prefix, just relative path)
app/controllers/admin/music/songs_controller.rb
app/models/music/song.rb
config/routes.rb
test/controllers/admin/music/songs_controller_test.rb

# ❌ WRONG - Do not use web-app/ prefix when already inside it
web-app/app/controllers/...  # You're already IN web-app!
```

### Quick Reference Table

**When in PROJECT ROOT** (`/home/shane/dev/the-greatest`):

| File Type | Path Example |
|-----------|--------------|
| Documentation | `docs/todo.md` |
| Task files | `docs/todos/077-task.md` |
| AGENTS.md | `AGENTS.md` |
| Controllers | `web-app/app/controllers/admin/music/songs_controller.rb` |
| Models | `web-app/app/models/music/song.rb` |
| Tests | `web-app/test/controllers/admin/music/songs_controller_test.rb` |

**When in RAILS ROOT** (`/home/shane/dev/the-greatest/web-app`):

| File Type | Path Example |
|-----------|--------------|
| Documentation | `../docs/todo.md` |
| Task files | `../docs/todos/077-task.md` |
| AGENTS.md | `../AGENTS.md` |
| Controllers | `app/controllers/admin/music/songs_controller.rb` |
| Models | `app/models/music/song.rb` |
| Tests | `test/controllers/admin/music/songs_controller_test.rb` |

### Common Mistakes to Avoid

1. **❌ DON'T** use `../` when you're in PROJECT ROOT - it goes outside the project!
2. **❌ DON'T** use `web-app/` prefix when you're already inside web-app/
3. **✅ DO** run `pwd` first to check your location
4. **✅ DO** use the correct path based on your working directory

### Emergency Fix: Check Absolute Paths

If unsure, use absolute paths to verify:
```bash
# Check if file exists before reading
ls -la /home/shane/dev/the-greatest/docs/todo.md
ls -la /home/shane/dev/the-greatest/web-app/app/models/music/song.rb
```

## Core Development Principles

### 1. ALWAYS Use Rails Generators

**CRITICAL:** NEVER manually create controllers, models, jobs, or other Rails files. ALWAYS use generators to ensure test files are created automatically.

```bash
# ✅ Correct - Creates file + test + follows conventions
cd web-app
bin/rails generate controller Admin::Music::Artists index show new edit
bin/rails generate model Music::Artist name:string slug:string:uniq
bin/rails generate sidekiq:job music/calculate_artist_ranking
bin/rails generate component Admin::SearchComponent url placeholder

# ❌ Wrong - No test file, easy to make mistakes
touch app/controllers/admin/music/artists_controller.rb
touch app/models/music/artist.rb
```

**Why this matters:**
- Generators automatically create test files in correct locations with proper namespacing
- Follow Rails naming conventions and file structure exactly
- Set up boilerplate code correctly (inheritance, module structure, etc.)
- Prevent common mistakes like missing test files or wrong paths
- **It's extremely annoying to add test files manually after the fact**

**Note:** Even for admin controllers and namespaced resources, use generators first, then customize.

### 2. Namespacing Requirements
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

### Key Architecture Changes (2025-09-16)
- **Incremental saving**: Items saved after each successful provider (enables background jobs)
- **Force providers**: Use `force_providers: true` to re-enrich existing items
- **Background job ready**: Async providers can launch Sidekiq jobs and return success immediately
- **Association persistence**: Items saved after every successful provider to persist both attribute changes and associations

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

## Background Jobs

### Generating Sidekiq Jobs
**CRITICAL:** Always use the `sidekiq:job` generator (NOT `job` or ActiveJob):
```bash
cd web-app
bin/rails generate sidekiq:job music/import_song_list_from_musicbrainz_series
```

This creates:
- `app/sidekiq/music/import_song_list_from_musicbrainz_series_job.rb`
- `test/sidekiq/music/import_song_list_from_musicbrainz_series_job_test.rb`

**DO NOT** use `bin/rails generate job` as it creates ActiveJob instead of Sidekiq jobs.

### Queue Usage
**CRITICAL:** Always use the default queue unless specifically needed:
```ruby
# ✅ Correct - uses default queue
class Music::ImportSongListJob
  include Sidekiq::Job
  # No queue_as needed
end

# ❌ Wrong - unnecessary custom queue
class Music::ImportSongListJob
  include Sidekiq::Job
  queue_as :music_import  # Don't do this
end

# ✅ Correct - custom queue for rate-limited API
class Ai::DescriptionJob
  include Sidekiq::Job
  queue_as :ai_serial  # OK for serial AI API calls
end
```

**Only use named queues for:**
- Serial jobs that interact with rate-limited external APIs (AI services, etc.)
- Jobs that must be processed sequentially to avoid API throttling

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

1. **Not using generators:** NEVER manually create controllers, models, or jobs - ALWAYS use `rails generate` to ensure test files are created
2. **Wrong working directory:** Always `cd web-app/` first
3. **Fixture references:** Check actual fixture names before using
4. **Enum syntax:** Use Rails 8 format with colon prefix
5. **Namespacing:** Media-specific code must be namespaced
6. **Documentation location:** All docs go in top-level `docs/`, not `web-app/docs/`

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