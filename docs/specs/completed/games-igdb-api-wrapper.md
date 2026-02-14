# Games IGDB API Wrapper

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2026-02-13
- **Started**: 2026-02-13
- **Completed**: 2026-02-13
- **Developer**: AI Agent

## Overview
Build a Ruby API wrapper for the [IGDB (Internet Game Database) API v4](https://api-docs.igdb.com/) under the `Games::Igdb` namespace. The wrapper follows the same architecture as `Music::Musicbrainz` (BaseClient → Search classes → consumed by future Providers). It covers authentication (Twitch OAuth2 client credentials), the Apicalypse query language, rate limiting, and search classes for the 10 entities needed to populate the Games data model.

**Scope**: Wrapper classes and tests only. No data importers/providers that consume the wrapper (those come in a later task).

**Non-goals**: Protobuf support, webhook support, multi-query endpoint, image downloading/processing.

## Context & Links
- MusicBrainz wrapper (pattern to follow): `app/lib/music/musicbrainz/`
- Games data model: `app/models/games/`
- Identifier types: `app/models/identifier.rb` (lines 56-58: `games_igdb_id: 400`, `games_rawg_id: 401`, `games_igdb_company_id: 410`)
- IGDB API docs: https://api-docs.igdb.com/
- Twitch OAuth2 docs: https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/
- Apicalypse syntax: https://apicalypse.io/syntax/
- Spec instructions: `docs/spec-instructions.md`

## Interfaces & Contracts

### Class Hierarchy

```
Games::Igdb::Configuration         - env vars, token caching, validation
Games::Igdb::Authentication        - Twitch OAuth2 token management (auto-refresh)
Games::Igdb::Exceptions            - error hierarchy (mirrors Music::Musicbrainz::Exceptions)
Games::Igdb::BaseClient            - HTTP layer (Faraday, POST requests, auth headers)
Games::Igdb::Query                 - Apicalypse query builder DSL
Games::Igdb::RateLimiter           - 4 req/sec rate limiting + 429 retry

Games::Igdb::Search::BaseSearch    - abstract search (shared logic)
  ├── GameSearch                   - games endpoint
  ├── CompanySearch                - companies endpoint
  ├── PlatformSearch               - platforms endpoint
  ├── GenreSearch                  - genres endpoint
  ├── CoverSearch                  - covers endpoint
  ├── FranchiseSearch              - franchises endpoint
  ├── GameModeSearch               - game_modes endpoint
  ├── ThemeSearch                  - themes endpoint
  ├── KeywordSearch                - keywords endpoint
  └── PlayerPerspectiveSearch      - player_perspectives endpoint
```

### File Structure

```
app/lib/games/igdb/
├── configuration.rb
├── authentication.rb
├── exceptions.rb
├── base_client.rb
├── query.rb
├── rate_limiter.rb
└── search/
    ├── base_search.rb
    ├── game_search.rb
    ├── company_search.rb
    ├── platform_search.rb
    ├── genre_search.rb
    ├── cover_search.rb
    ├── franchise_search.rb
    ├── game_mode_search.rb
    ├── theme_search.rb
    ├── keyword_search.rb
    └── player_perspective_search.rb

test/lib/games/igdb/
├── configuration_test.rb
├── authentication_test.rb
├── base_client_test.rb
├── query_test.rb
├── rate_limiter_test.rb
└── search/
    ├── base_search_test.rb
    ├── game_search_test.rb
    ├── company_search_test.rb
    ├── platform_search_test.rb
    ├── genre_search_test.rb
    ├── cover_search_test.rb
    ├── franchise_search_test.rb
    ├── game_mode_search_test.rb
    ├── theme_search_test.rb
    ├── keyword_search_test.rb
    └── player_perspective_search_test.rb
```

### Configuration

**Environment variables** (already added by user):
- `TWITCH_API_CLIENT_ID` — Twitch application client ID
- `TWITCH_API_CLIENT_SECRET` — Twitch application client secret

**Configuration class** (mirrors `Music::Musicbrainz::Configuration`):

| Attribute | Default | Source |
|---|---|---|
| `client_id` | (required) | `ENV["TWITCH_API_CLIENT_ID"]` |
| `client_secret` | (required) | `ENV["TWITCH_API_CLIENT_SECRET"]` |
| `api_base_url` | `https://api.igdb.com/v4` | `ENV["IGDB_API_URL"]` or default |
| `auth_url` | `https://id.twitch.tv/oauth2/token` | `ENV["TWITCH_AUTH_URL"]` or default |
| `timeout` | 30 | seconds |
| `open_timeout` | 10 | seconds |
| `logger` | `Rails.logger` | |
| `user_agent` | `"The Greatest Games App/1.0"` | |
| `max_retries` | 3 | for 429 rate-limit retries |

**Validation**: Raises `Games::Igdb::Exceptions::ConfigurationError` if `client_id` or `client_secret` are blank.

### Authentication

**Token flow** (Twitch client_credentials):
1. `POST https://id.twitch.tv/oauth2/token?client_id=X&client_secret=Y&grant_type=client_credentials`
2. Response: `{"access_token": "abc", "expires_in": 5587808, "token_type": "bearer"}`
3. Cache token + expiry timestamp. Auto-refresh when within 5 minutes of expiry.

**Thread safety**: Use `Mutex` for token refresh to prevent concurrent refresh races.

**Headers on every API request**:
```
Client-ID: {client_id}
Authorization: Bearer {access_token}
```

### BaseClient — HTTP Layer

**Key differences from MusicBrainz BaseClient**:
- Uses **POST** (not GET) for all data requests
- Request body is **plain text** (Apicalypse query), not URL params
- Requires auth headers (`Client-ID`, `Authorization: Bearer`)
- Integrates `RateLimiter` before each request
- Integrates `Authentication` for transparent token management

**Method signature**:
```ruby
# reference only
def post(endpoint, query_string)
  # 1. Ensure authenticated (auto-refresh if needed)
  # 2. Rate limit (sleep if needed)
  # 3. POST to endpoint with query body + auth headers
  # 4. Parse JSON response
  # 5. Return structured response hash
end
```

**Structured response** (matches MusicBrainz pattern):
```json
{
  "success": true,
  "data": [{"id": 1025, "name": "Zelda..."}],
  "errors": [],
  "metadata": {
    "endpoint": "games",
    "query": "fields name; search \"zelda\"; limit 5;",
    "response_time": 0.234,
    "status_code": 200
  }
}
```

### Query Builder — Apicalypse DSL

Builds Apicalypse query strings from Ruby method calls. Immutable (each method returns a new Query).

**API**:

| Method | Apicalypse | Example |
|---|---|---|
| `.fields(*names)` | `fields name, rating;` | `.fields(:name, :rating)` |
| `.fields_all` | `fields *;` | `.fields_all` |
| `.exclude(*names)` | `exclude storyline;` | `.exclude(:storyline)` |
| `.where(conditions)` | `where rating > 75;` | `.where("rating > 75")` |
| `.where(field: value)` | `where id = 42;` | `.where(id: 42)` |
| `.where(field: [v1,v2])` | `where id = (1,2);` | `.where(id: [1, 2])` |
| `.search(term)` | `search "zelda";` | `.search("zelda")` |
| `.sort(field, dir)` | `sort rating desc;` | `.sort(:rating, :desc)` |
| `.limit(n)` | `limit 50;` | `.limit(50)` |
| `.offset(n)` | `offset 100;` | `.offset(100)` |
| `.to_s` | full query string | returns assembled query |

**Validation**:
- `limit` must be 1..500 (IGDB max)
- `offset` must be >= 0
- At least one clause required (raises `QueryError` on empty)

### Rate Limiter

Simple token-bucket rate limiter: 4 requests per second.

**Behavior**:
- Before each request, check if we can proceed. If not, sleep until a slot opens.
- On HTTP 429 response: exponential backoff retry (up to `max_retries`).
- Thread-safe via `Mutex`.

### Exception Hierarchy

Mirrors `Music::Musicbrainz::Exceptions` with additions for auth:

```
Games::Igdb::Exceptions::Error < StandardError
  ├── ConfigurationError
  ├── AuthenticationError          # NEW: Twitch OAuth failures
  ├── NetworkError
  │   └── TimeoutError
  ├── HttpError (status_code, response_body)
  │   ├── ClientError (4xx)
  │   │   ├── BadRequestError (400)
  │   │   ├── UnauthorizedError (401)   # NEW: expired/invalid token
  │   │   ├── NotFoundError (404)
  │   │   └── RateLimitError (429)      # NEW: rate limit exceeded
  │   └── ServerError (5xx)
  ├── ParseError
  └── QueryError
```

### Search Classes

Each search class wraps a specific IGDB endpoint. They share a base class pattern.

**BaseSearch interface** (mirrors `Music::Musicbrainz::Search::BaseSearch`):

| Method | Description |
|---|---|
| `#initialize(client = nil)` | Accepts optional BaseClient |
| `#endpoint` | Returns endpoint string (e.g., `"games"`) |
| `#find_by_id(id, fields:)` | Lookup single entity by IGDB ID |
| `#find_by_ids(ids, fields:)` | Lookup multiple entities by IGDB IDs |
| `#search(term, fields:, limit:, offset:)` | Full-text search |
| `#where(conditions, fields:, sort:, limit:, offset:)` | Filtered query |
| `#all(fields:, limit:, offset:, sort:)` | Paginated listing |
| `#count(conditions)` | Count matching records |

**GameSearch — additional convenience methods**:

| Method | Description |
|---|---|
| `#search_by_name(name, **opts)` | `search "name"; fields ...; where game_type = 0;` (main games) |
| `#find_with_details(id)` | Expands: cover, genres, platforms, involved_companies, franchises, themes, game_modes, keywords, player_perspectives |
| `#by_platform(platform_id, **opts)` | Filter games by platform |

**CompanySearch — additional convenience methods**:

| Method | Description |
|---|---|
| `#search_by_name(name, **opts)` | `search "name"; fields ...;` |
| `#find_with_details(id)` | Expands: developed, published, logo |

**PlatformSearch — additional convenience methods**:

| Method | Description |
|---|---|
| `#search_by_name(name, **opts)` | `search "name"; fields ...;` |
| `#by_family(family_id, **opts)` | Filter by platform_family |

**Simple entity searches** (GenreSearch, GameModeSearch, ThemeSearch, KeywordSearch, PlayerPerspectiveSearch, FranchiseSearch):
- Inherit BaseSearch
- Override `#endpoint` and `#default_fields`
- No additional convenience methods needed (they're simple name/slug entities)

**CoverSearch**:

| Method | Description |
|---|---|
| `#find_by_game_id(game_id)` | `where game = {game_id}; fields image_id, url, width, height;` |
| `#find_by_game_ids(game_ids)` | Batch cover lookup |
| `#image_url(image_id, size:)` | Build full image URL from image_id and size constant |

**Image size constants** (on CoverSearch or a shared module):

| Constant | IGDB Size | Pixels |
|---|---|---|
| `SIZE_THUMB` | `t_thumb` | 90x90 |
| `SIZE_COVER_SMALL` | `t_cover_small` | 90x128 |
| `SIZE_COVER_BIG` | `t_cover_big` | 264x374 |
| `SIZE_720P` | `t_720p` | 1280x720 |
| `SIZE_1080P` | `t_1080p` | 1920x1080 |

### Behaviors (pre/postconditions)

**Preconditions**:
- `TWITCH_API_CLIENT_ID` and `TWITCH_API_CLIENT_SECRET` env vars must be set
- Network connectivity to `id.twitch.tv` (auth) and `api.igdb.com` (data)

**Postconditions**:
- All public search methods return the structured response hash: `{success:, data:, errors:, metadata:}`
- On auth failure: raises `AuthenticationError` (not silently retried)
- On rate limit: transparently retries with backoff up to `max_retries`, then raises `RateLimitError`
- On network failure: raises `NetworkError` or `TimeoutError` with original error preserved

**Edge cases & failure modes**:
- Empty query string → `QueryError`
- Invalid IGDB ID (non-integer) → `QueryError`
- Token expired mid-request → auto-refresh and retry once; if still fails → `UnauthorizedError`
- IGDB returns empty array `[]` → `{success: true, data: [], ...}` (not an error)
- IGDB returns 404 for nonexistent endpoint → `NotFoundError`
- Connection drops mid-response → `NetworkError`

### Non-Functionals

- **Rate limiting**: 4 req/sec enforced by wrapper; 429 retry with exponential backoff
- **Token caching**: Single token cached in-memory per Configuration instance; refreshed within 5 min of expiry
- **Thread safety**: Token refresh and rate limiter use `Mutex`
- **No N+1**: `find_with_details` uses IGDB field expansion (dot notation) to avoid follow-up requests
- **Timeout**: 30s request timeout, 10s connection timeout (configurable)

## Acceptance Criteria

### Configuration & Auth
- [x] `Games::Igdb::Configuration` reads `TWITCH_API_CLIENT_ID` and `TWITCH_API_CLIENT_SECRET` from env
- [x] `Configuration` raises `ConfigurationError` when client_id or client_secret is blank
- [x] `Configuration` validates API URL format (HTTP/HTTPS)
- [x] `Games::Igdb::Authentication` obtains access token via Twitch client_credentials grant
- [x] `Authentication` caches token and auto-refreshes when within 5 min of expiry
- [x] `Authentication` raises `AuthenticationError` on Twitch auth failure

### BaseClient & HTTP
- [x] `Games::Igdb::BaseClient` sends POST requests with Apicalypse query in body
- [x] `BaseClient` includes `Client-ID` and `Authorization: Bearer` headers on every request
- [x] `BaseClient` returns structured response hash `{success:, data:, errors:, metadata:}`
- [x] `BaseClient` raises appropriate exceptions for 400, 401, 404, 429, 5xx responses
- [x] `BaseClient` wraps Faraday network errors in `NetworkError`/`TimeoutError`
- [x] `BaseClient` integrates rate limiter (calls limiter before each request)

### Query Builder
- [x] `Games::Igdb::Query` builds valid Apicalypse query strings
- [x] `Query` supports: fields, exclude, where (string and hash), search, sort, limit, offset
- [x] `Query` validates limit (1..500) and offset (>= 0)
- [x] `Query` raises `QueryError` on empty query (no clauses)
- [x] `Query` is immutable (each method returns a new Query instance)

### Rate Limiter
- [x] `Games::Igdb::RateLimiter` enforces 4 requests per second
- [x] `RateLimiter` sleeps when bucket is empty (doesn't drop requests)
- [x] `RateLimiter` is thread-safe

### Search Classes
- [x] All 10 search classes implement: `find_by_id`, `find_by_ids`, `search`, `where`, `all`, `count`
- [x] `GameSearch#find_with_details` returns game with expanded cover, genres, platforms, involved_companies, franchises, themes, game_modes, keywords, player_perspectives
- [x] `GameSearch#search_by_name` performs full-text search with correct fields
- [x] `CompanySearch#find_with_details` returns company with expanded games and logo
- [x] `CoverSearch#find_by_game_id` returns cover data for a specific game
- [x] `CoverSearch#image_url` builds correct IGDB image URLs for all size constants
- [x] All search classes handle IGDB returning empty array `[]` as success (not error)

### Exceptions
- [x] Exception hierarchy mirrors MusicBrainz pattern with `AuthenticationError`, `UnauthorizedError`, `RateLimitError` additions
- [x] All exceptions preserve context (status_code, response_body, original_error as appropriate)

### Testing
- [x] All classes have unit tests using Minitest + Mocha
- [x] HTTP calls are stubbed (no real API calls in tests)
- [x] Auth token requests are stubbed
- [x] Tests verify query construction, response parsing, error handling
- [x] Tests follow existing patterns in `test/lib/music/musicbrainz/`

### Golden Examples

**Example 1: Search for a game by name**

```text
Input:
  search = Games::Igdb::Search::GameSearch.new
  result = search.search_by_name("The Legend of Zelda: Breath of the Wild")

Query sent to IGDB:
  POST https://api.igdb.com/v4/games
  Headers: Client-ID: xxx, Authorization: Bearer yyy
  Body: search "The Legend of Zelda: Breath of the Wild"; fields name, slug, summary, first_release_date, cover.image_id, genres.name, platforms.name; where game_type = 0; limit 10;

Output:
  {
    success: true,
    data: [
      {"id" => 7346, "name" => "The Legend of Zelda: Breath of the Wild", "slug" => "the-legend-of-zelda-breath-of-the-wild", ...}
    ],
    errors: [],
    metadata: {endpoint: "games", query: "search \"The Legend...\"; ...", response_time: 0.234, status_code: 200}
  }
```

**Example 2: Query builder usage**

```text
Input:
  query = Games::Igdb::Query.new
    .fields(:name, :rating, :first_release_date)
    .where("rating > 85")
    .where(platforms: [48, 49])
    .sort(:rating, :desc)
    .limit(25)
    .to_s

Output:
  "fields name, rating, first_release_date; where rating > 85 & platforms = (48, 49); sort rating desc; limit 25;"
```

**Example 3: Cover image URL construction**

```text
Input:
  cover_search = Games::Igdb::Search::CoverSearch.new
  cover_search.image_url("co1abc", size: Games::Igdb::Search::CoverSearch::SIZE_COVER_BIG)

Output:
  "https://images.igdb.com/igdb/image/upload/t_cover_big/co1abc.jpg"
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns (`Music::Musicbrainz` namespace structure); do not introduce new architecture.
- Namespace everything under `Games::Igdb` (not top-level).
- Respect snippet budget (≤40 lines per snippet).
- Do not duplicate authoritative code; **link to file paths**.
- Use Faraday for HTTP (already in Gemfile for MusicBrainz).
- Use Mocha for test mocking (already used project-wide).

### Required Outputs
- All files listed in "File Structure" above (implementation + tests).
- All Acceptance Criteria passing.
- Updated sections: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → collect MusicBrainz wrapper patterns for direct modeling
2) codebase-analyzer → verify Configuration/BaseClient integration points
3) web-search-researcher → IGDB API docs if clarification needed during implementation
4) technical-writer → update docs and cross-refs

### Test Seed / Fixtures
- No database fixtures needed (wrapper is pure API client, no ActiveRecord).
- Tests use inline response hashes (matching MusicBrainz test pattern).
- Stub `Faraday::Connection` or mock at the client level with Mocha.
- Stub `Net::HTTP` / Faraday for Twitch auth token requests.

---

## Implementation Notes (living)
- Approach taken: Mirrored `Music::Musicbrainz` architecture exactly, adding Authentication, RateLimiter, and Query classes for IGDB-specific needs (OAuth2, rate limiting, Apicalypse DSL)
- Important decisions:
  - Used private `perform_refresh!` method in Authentication to avoid Mutex deadlock (Ruby Mutex is non-reentrant). Public `refresh_token!` and `access_token` both synchronize at their level then delegate to the unsynchronized private method.
  - Query builder is fully immutable (each method returns new Query instance)
  - BaseClient handles 401 retry (auto-refresh token once) and 429 retry (exponential backoff up to max_retries)
  - Simple entity searches (Genre, GameMode, Theme, Keyword, PlayerPerspective, Franchise) only override `endpoint` and `default_fields` - no extra methods needed
  - `count` method uses IGDB's `/endpoint/count` sub-endpoint

### Key Files Touched (paths only)
- `app/lib/games/igdb/configuration.rb`
- `app/lib/games/igdb/authentication.rb`
- `app/lib/games/igdb/exceptions.rb`
- `app/lib/games/igdb/base_client.rb`
- `app/lib/games/igdb/query.rb`
- `app/lib/games/igdb/rate_limiter.rb`
- `app/lib/games/igdb/search/base_search.rb`
- `app/lib/games/igdb/search/game_search.rb`
- `app/lib/games/igdb/search/company_search.rb`
- `app/lib/games/igdb/search/platform_search.rb`
- `app/lib/games/igdb/search/genre_search.rb`
- `app/lib/games/igdb/search/cover_search.rb`
- `app/lib/games/igdb/search/franchise_search.rb`
- `app/lib/games/igdb/search/game_mode_search.rb`
- `app/lib/games/igdb/search/theme_search.rb`
- `app/lib/games/igdb/search/keyword_search.rb`
- `app/lib/games/igdb/search/player_perspective_search.rb`
- `test/lib/games/igdb/` (all corresponding test files)

### Challenges & Resolutions
- Thread-safety in Authentication: `refresh_token!` called from both `access_token` (holding mutex) and `BaseClient.handle_unauthorized` (no mutex). Solved with private `perform_refresh!` pattern to avoid non-reentrant Mutex deadlock.

### Deviations From Plan
- Configuration raises `ConfigurationError` (as spec says) instead of `ArgumentError` (as MusicBrainz does). This is intentional per spec.

## Acceptance Results
- Date: 2026-02-13
- 124 new tests, all passing (225 assertions)
- Full suite: 3,666 tests, 9,556 assertions, 0 failures

## Future Improvements
- Protobuf support for higher performance (`POST /v4/games.pb`)
- Multi-query endpoint (`POST /v4/multiquery`) for batching
- Release dates search class (for precise release date handling per region)
- Screenshots/videos search classes
- Webhook integration (requires Pro/Enterprise plan)
- Data importer providers that consume this wrapper (next task)

## Related PRs
- Pending commit (not yet pushed)

## Documentation Updated
- [x] Spec file updated with implementation notes, acceptance results, and all criteria checked
- [ ] `documentation.md` — deferred until PR review
