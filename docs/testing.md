# The Greatest - Testing Guide

## Core Testing Philosophy
- **Unit/Integration**: Minitest with fixtures, Mocha for stubs and mocks
- **E2E**: Playwright with TypeScript, running against local dev instances
- **Coverage Goal**: 100% unit/integration test coverage; E2E coverage for all user-facing features
- **Scope**: Test public methods only - never test private methods
- **New features MUST include E2E tests** for any user-facing pages or flows

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

## Authentication in Tests

### Using `sign_in_as` Helper

The `test_helper.rb` provides a `sign_in_as` helper for integration tests that handles user authentication. For most tests, you'll want to stub the authentication service to bypass JWT validation:

```ruby
# In your test
test "admin can access dashboard" do
  sign_in_as(@admin_user, stub_auth: true)
  get admin_dashboard_path
  assert_response :success
end
```

**Parameters:**
- `user` - The user fixture to sign in as
- `stub_auth: true` - (Optional) Stubs the `Services::AuthenticationService` to bypass JWT validation. Use this in almost all tests to avoid real authentication.

**When to use `stub_auth: true`:**
- Admin controller tests (always)
- Any test that needs authentication but doesn't specifically test the authentication flow
- Tests that would fail JWT validation (most tests)

**When NOT to use `stub_auth: true`:**
- Tests specifically testing the authentication flow itself
- Integration tests where you want to test the full authentication stack

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

## Controller Testing Best Practices

Controller tests should verify that controllers handle requests correctly and return appropriate responses. **Do not test view implementation details.**

### ✅ DO: Test Controller Behavior

```ruby
test "should handle search with results without error" do
  artist = music_artists(:the_beatles)
  artist_results = [{ id: artist.id.to_s, score: 10.0, source: { name: artist.name } }]

  ::Search::Music::Search::ArtistGeneral.stubs(:call).returns(artist_results)
  ::Search::Music::Search::AlbumGeneral.stubs(:call).returns([])
  ::Search::Music::Search::SongGeneral.stubs(:call).returns([])

  get search_path(q: "Beatles")
  assert_response :success
end
```

**Why?** This verifies the controller handles requests without errors. A designer can completely redesign the page and the test still passes.

### ❌ DON'T: Test Specific HTML Structure

```ruby
# BAD - Brittle, fragile test
test "should display search results" do
  get search_path(q: "Beatles")
  assert_response :success
  assert_select ".card-title", "The Beatles"
  assert_select "h2.text-2xl", "Artists"
  assert_select ".badge.badge-ghost", "1"
  assert_select "a[href=?]", albums_path, text: "Top Albums"
end
```

**Why not?** This breaks when a designer changes CSS classes, heading sizes, badge styles, or link text. These are all reasonable UI changes that shouldn't require updating tests.

### ✅ DO: Test HTTP Response Codes

```ruby
test "should return 404 for non-existent resource" do
  get artist_path("non-existent-slug")
  assert_response :not_found
end

test "should redirect after successful update" do
  patch admin_artist_path(@artist), params: { artist: { name: "New Name" } }
  assert_redirected_to admin_artist_path(@artist)
end
```

### ✅ DO: Test Method Parameters (Business Logic)

```ruby
test "should call search with correct size parameters" do
  ::Search::Music::Search::ArtistGeneral.expects(:call).with("test", size: 25).returns([])
  ::Search::Music::Search::AlbumGeneral.expects(:call).with("test", size: 25).returns([])
  ::Search::Music::Search::SongGeneral.expects(:call).with("test", size: 10).returns([])

  get search_path(q: "test")
  assert_response :success
end
```

**Why?** This tests important business logic (result limits) that should remain consistent.

### Rule of Thumb
**If a designer could reasonably change it without consulting a developer, don't test it.**

Examples of what designers can change:
- CSS classes and styling
- Exact text content and copy
- Element order and layout
- Typography and spacing
- Colors and visual design

Examples of what should be tested:
- HTTP response codes
- No errors/exceptions
- Business logic parameters
- Data transformations
- Authentication/authorization

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
- **Never test HTML structure, CSS classes, or UI layout in controller tests** - These are fragile and break when designers make reasonable UI changes. Test controller behavior, not view implementation.

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

## E2E Testing (Playwright)

For full details, see [E2E Testing Feature Doc](features/e2e-testing.md).

### Overview
Playwright E2E tests run against local dev instances with real Firebase authentication. They verify that pages load correctly, navigation works, and user flows (login, logout, admin browsing) function end-to-end.

### When to Write E2E Tests
**All new user-facing features MUST include E2E tests.** Specifically:
- New public pages or routes
- New admin pages or CRUD interfaces
- Changes to navigation or layout
- New auth flows or permission checks
- Any feature a user interacts with in a browser

### Running E2E Tests
```bash
cd web-app
yarn test:e2e            # Full suite (headless)
yarn test:e2e:headed     # With visible browser
yarn test:e2e:ui         # Interactive UI mode
yarn test:e2e:debug      # Debug with inspector
```

**Prerequisites**: Local dev server running, `e2e/.env` configured with test account credentials, Chromium installed (`npx playwright install chromium`).

### Making Views E2E-Testable

Add `data-testid` attributes to views to give Playwright stable, unambiguous selectors. This is **required** when:
- An element has no accessible role, text, or label that uniquely identifies it (e.g., icon-only buttons)
- Multiple elements on the page share the same role and name (e.g., sidebar "Artists" link vs. dashboard card "Artists" link)
- The element's visible text or structure is likely to change

**Naming convention**: Use kebab-case, descriptive names scoped to the component:
```erb
<%# Good - stable, descriptive test IDs %>
<aside data-testid="admin-sidebar">
<%= link_to path, data: { testid: "back-button" } do %>
<div data-testid="stat-card-artists">

<%# Bad - too generic or tied to implementation %>
<aside data-testid="aside1">
<div data-testid="div-wrapper">
```

**Locator priority in Playwright tests** (prefer top of list):
1. `page.getByRole()` — buttons, links, headings (most accessible)
2. `page.getByText()` — visible text content
3. `page.getByLabel()` / `page.getByPlaceholder()` — form inputs
4. `page.getByTestId()` — `data-testid` attributes (when above options are ambiguous)
5. `page.locator()` — CSS selectors (last resort)

### Existing `data-testid` Attributes
| Attribute | Location | Purpose |
|---|---|---|
| `data-testid="admin-sidebar"` | `app/views/admin/shared/_sidebar.html.erb` | Scopes sidebar link selectors |
| `data-testid="back-button"` | Artist, album, song show pages | Identifies icon-only back arrow links |

### E2E Test Structure
```
web-app/e2e/
  playwright.config.ts      # Config (baseURL, workers, auth project)
  auth/auth.setup.ts        # Login once, save session for reuse
  fixtures/auth.ts           # Custom test fixture with page objects
  pages/                     # Page Object Models (locators + actions)
  tests/                     # Test specs organized by domain/area
```

### Key Differences from Minitest
| | Minitest | Playwright E2E |
|---|---|---|
| **Language** | Ruby | TypeScript |
| **Target** | Rails test env with fixtures | Live local dev with real data |
| **Auth** | Stubbed JWT via `sign_in_as` | Real Firebase email/password |
| **Scope** | Controller behavior, models, services | Full browser user journeys |
| **Speed** | Fast (parallel, in-process) | Slower (real browser, network) |
| **Data** | Fixtures (isolated) | Shared dev database (read-only) |