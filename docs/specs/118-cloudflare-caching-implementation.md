# 118 - Cloudflare Caching Implementation

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2026-01-16
- **Started**:
- **Completed**:
- **Developer**: TBD

## Overview
Implement HTTP caching headers in Rails controllers to enable Cloudflare edge caching for public pages. This will significantly reduce server load and improve global page load times. Admin pages will be explicitly excluded from caching.

**Scope:**
- Add cache-control headers to public controllers (albums, songs, artists, categories, homepage, lists)
- Explicitly prevent caching on admin routes and search pages
- Configure Cloudflare Cache Rule to cache HTML pages
- Verify NGINX passes headers through to Cloudflare

**Non-goals (future spec):**
- Cloudflare cache purging API integration
- Programmatic cache invalidation on data changes

## Context & Links
- Related tasks: `docs/specs/completed/050-cloudflare-caching-strategy.md` (draft, not implemented)
- Source files (authoritative): `app/controllers/application_controller.rb`, `app/controllers/admin/base_controller.rb`
- External docs: [Cloudflare Cache Rules](https://developers.cloudflare.com/cache/how-to/cache-rules/), [Rails expires_in](https://api.rubyonrails.org/classes/ActionController/ConditionalGet.html)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required.

### Endpoints
Cache headers will be applied to these public endpoints:

| Verb | Path Pattern | Cache Duration | Auth |
|------|--------------|----------------|------|
| GET | `/` (all domains) | 6 hours | public |
| GET | `/albums` | 6 hours | public |
| GET | `/albums/:id` | 24 hours | public |
| GET | `/albums/lists` | 6 hours | public |
| GET | `/albums/lists/:id` | 24 hours | public |
| GET | `/albums/categories/:id` | 6 hours | public |
| GET | `/songs` | 6 hours | public |
| GET | `/songs/:id` | 24 hours | public |
| GET | `/songs/lists` | 6 hours | public |
| GET | `/songs/lists/:id` | 24 hours | public |
| GET | `/artists` | 6 hours | public |
| GET | `/artists/:id` | 24 hours | public |
| GET | `/artists/categories/:id` | 6 hours | public |
| GET | `/categories/:id` | 6 hours | public |
| GET | `/lists` | 6 hours | public |

These endpoints will be explicitly excluded from caching:

| Verb | Path Pattern | Headers | Auth |
|------|--------------|---------|------|
| ALL | `/admin/*` | `no-store, private` | admin/editor |
| ALL | `/avo/*` | `no-store, private` | admin |
| ALL | `/sidekiq-admin/*` | `no-store, private` | admin |
| POST | `/auth/*` | `no-store, private` | n/a |
| GET | `/search` | `no-store, private` | public |

> Source of truth: `config/routes.rb`

### Schemas (JSON)
N/A - this feature only adds HTTP headers.

### Behaviors (pre/postconditions)

**Preconditions:**
- Request is a GET request (caching only applies to GET)
- For public caching: route is not in admin namespace

**Postconditions/effects:**
- Public pages return `Cache-Control: public, max-age=X, stale-while-revalidate=Y`
- Admin pages return `Cache-Control: no-store, no-cache, must-revalidate, private`
- Cloudflare caches public pages at edge (CF-Cache-Status: HIT after first request)

**Edge cases & failure modes:**
- Pages with flash messages should still be cacheable (flash is shown via session, not page content)
- Search results are NOT cached (dynamic, query-dependent)
- Paginated pages use query params (`/albums?page=2`) - Cloudflare query string caching to be configured separately
- 404 pages should not be cached long-term (short TTL or no-cache)

### Non-Functionals
- **Performance**: First request to origin, subsequent requests served from Cloudflare edge
- **Latency**: Cached pages should return in <100ms from edge
- **Security**: Admin pages must NEVER be cached publicly
- **Roles**: No role-based cache variation (all users see same cached content)

### Cloudflare Configuration

**Important:** Cloudflare does NOT cache HTML pages by default. A Cache Rule must be configured to enable caching.

**Required Cache Rule (Cloudflare Dashboard > Caching > Cache Rules):**

| Field | Value |
|-------|-------|
| Rule name | Cache HTML pages |
| Expression | `(http.request.uri.path eq "/" or starts_with(http.request.uri.path, "/albums") or starts_with(http.request.uri.path, "/songs") or starts_with(http.request.uri.path, "/artists") or starts_with(http.request.uri.path, "/categories") or starts_with(http.request.uri.path, "/lists"))` |
| Cache eligibility | Eligible for cache |
| Edge TTL | Use origin Cache-Control header (respect origin) |
| Browser TTL | Use origin Cache-Control header (respect origin) |

**Alternative simpler expression** (if you want to cache all non-admin HTML):
```
(not starts_with(http.request.uri.path, "/admin") and not starts_with(http.request.uri.path, "/avo") and not starts_with(http.request.uri.path, "/sidekiq") and not starts_with(http.request.uri.path, "/auth") and not starts_with(http.request.uri.path, "/search"))
```

**Why this is needed:**
- By default, Cloudflare only caches static assets (images, CSS, JS) based on file extension
- HTML pages (`text/html`) are never cached unless explicitly configured
- The Cache Rule tells Cloudflare to cache responses when origin sends `Cache-Control: public`
- Admin/search pages send `Cache-Control: private` so they won't be cached even with this rule

**Pagination note:**
- Pagination uses query params (`/albums?page=2`)
- By default, Cloudflare includes query strings in cache keys (each `?page=X` is cached separately)
- Verify this works after implementation; may need Cache Rule adjustment for query string handling

## Acceptance Criteria
- [ ] Public index pages return `Cache-Control: public, max-age=21600, stale-while-revalidate=3600` (6 hours, 1 hour SWR)
- [ ] Public show pages return `Cache-Control: public, max-age=86400, stale-while-revalidate=3600` (24 hours, 1 hour SWR)
- [ ] Search pages return `Cache-Control: no-store, no-cache, must-revalidate, private` (not cached)
- [ ] Admin pages return `Cache-Control: no-store, no-cache, must-revalidate, private`
- [ ] Auth endpoints return `Cache-Control: no-store, private`
- [ ] NGINX passes Cache-Control headers through to Cloudflare (verify with curl)
- [ ] Cloudflare Cache Rule configured to cache HTML pages with "Respect Origin" TTL
- [ ] Cloudflare respects headers (verify CF-Cache-Status: HIT on second request)
- [ ] Login button continues to work via client-side JS (no changes needed)
- [ ] CSRF tokens still work on cached pages (verified via form submissions)

### Golden Examples

**Public index page (albums):**
```text
Input: GET /albums
Output Headers:
  Cache-Control: public, max-age=21600, stale-while-revalidate=3600
  Vary: Accept-Encoding
```

**Public show page (album detail):**
```text
Input: GET /albums/nevermind
Output Headers:
  Cache-Control: public, max-age=86400, stale-while-revalidate=3600
  Vary: Accept-Encoding
```

**Admin page:**
```text
Input: GET /admin/albums
Output Headers:
  Cache-Control: no-store, no-cache, must-revalidate, private
  Pragma: no-cache
```

**Search page (not cached):**
```text
Input: GET /search?q=nirvana
Output Headers:
  Cache-Control: no-store, no-cache, must-revalidate, private
  Pragma: no-cache
```

**Verification command:**
```bash
curl -I https://thegreatestmusic.org/albums 2>/dev/null | grep -i cache-control
# Expected: Cache-Control: public, max-age=21600, stale-while-revalidate=3600

curl -I https://thegreatestmusic.org/albums 2>/dev/null | grep -i cf-cache-status
# First request: CF-Cache-Status: MISS
# Second request: CF-Cache-Status: HIT
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Respect snippet budget (≤40 lines).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → find existing before_action patterns in controllers
2) codebase-analyzer → verify admin controller inheritance chain
3) web-search-researcher → not needed (research complete)
4) technical-writer → update docs after implementation

### Test Seed / Fixtures
No fixtures needed - this is header-only verification via curl or request specs.

---

## Implementation Notes (living)

### Approach

Create a `Cacheable` concern with methods for different cache durations. Include in `ApplicationController` but only apply to specific actions in public controllers. Add explicit no-cache headers in `Admin::BaseController`.

### Key Files Touched (paths only)
- `app/controllers/concerns/cacheable.rb` (new)
- `app/controllers/application_controller.rb`
- `app/controllers/admin/base_controller.rb`
- `app/controllers/music/default_controller.rb`
- `app/controllers/music/albums_controller.rb`
- `app/controllers/music/songs_controller.rb`
- `app/controllers/music/artists_controller.rb`
- `app/controllers/music/categories_controller.rb`
- `app/controllers/music/searches_controller.rb`
- `app/controllers/music/lists_controller.rb`
- `app/controllers/music/albums/ranked_items_controller.rb`
- `app/controllers/music/songs/ranked_items_controller.rb`
- `app/controllers/music/artists/ranked_items_controller.rb`
- `app/controllers/music/albums/lists_controller.rb`
- `app/controllers/music/songs/lists_controller.rb`
- `app/controllers/music/albums/categories_controller.rb`
- `app/controllers/music/artists/categories_controller.rb`
- `app/controllers/auth_controller.rb`

### Reference Implementation (≤40 lines, non-authoritative)

```ruby
# app/controllers/concerns/cacheable.rb
# reference only
module Cacheable
  extend ActiveSupport::Concern

  private

  # 6 hours with 1 hour stale-while-revalidate (for index/list pages)
  def cache_for_index_page
    expires_in 6.hours, public: true, stale_while_revalidate: 1.hour
  end

  # 24 hours with 1 hour stale-while-revalidate (for show/detail pages)
  def cache_for_show_page
    expires_in 24.hours, public: true, stale_while_revalidate: 1.hour
  end

  # Explicitly prevent caching (for admin, auth, search)
  def prevent_caching
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, private'
    response.headers['Pragma'] = 'no-cache'
  end
end
```

**Usage in controllers:**
```ruby
# Public controller example
class Music::Albums::RankedItemsController < ApplicationController
  include Cacheable
  before_action :cache_for_index_page, only: [:index]
end

# Search controller (not cached)
class Music::SearchesController < ApplicationController
  include Cacheable
  before_action :prevent_caching
end
```

### Challenges & Resolutions
- *To be documented during implementation*

### Deviations From Plan
- *To be documented during implementation*

## Acceptance Results
- Date, verifier, artifacts (screenshots/links):

## Future Improvements
- Cloudflare cache purging API integration (separate spec)
- Cache warming after data imports
- Vary cache by query parameters (sort, filter)
- ETags for conditional requests (304 Not Modified)
- Real-time cache hit rate monitoring

## Related PRs
- #...

## Documentation Updated
- [ ] `documentation.md`
- [ ] Class docs
- [ ] `deployment/ENV.md` (no changes needed for this spec)
