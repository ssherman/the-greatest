# 119 - Cloudflare Cache Purging

## Status
- **Status**: Completed
- **Priority**: Medium
- **Created**: 2026-01-17
- **Started**: 2026-01-17
- **Completed**: 2026-01-17
- **Developer**: Claude

## Overview
Implement a Cloudflare cache purge feature accessible from the admin interface. Admins can click a button in the sidebar to purge the entire Cloudflare cache for all domains (music, movies, games, books). This is useful after bulk data imports, ranking recalculations, or when content needs immediate refresh.

**Scope:**
- Create a `Cloudflare::PurgeService` following existing HTTP client patterns
- Add admin controller endpoint for purge action (admin-only)
- Add "Purge Cache" button to admin sidebar under Global section
- Support all four domains with per-domain zone IDs via environment variables

**Non-goals:**
- Selective URL purging (future enhancement)
- Cache tag purging (requires Cloudflare Enterprise)
- Automatic purging on model changes

## Context & Links
- Related tasks: `docs/specs/118-cloudflare-caching-implementation.md` (implements caching headers)
- Source files to follow: `app/lib/music/musicbrainz/base_client.rb`, `app/lib/music/musicbrainz/exceptions.rb`
- External docs: [Cloudflare Purge Cache API](https://developers.cloudflare.com/api/resources/cache/methods/purge/)

## Interfaces & Contracts

### Domain Model (diffs only)
No database changes required.

### Endpoints
| Verb | Path | Purpose | Params/Body | Auth |
|------|------|---------|-------------|------|
| POST | /admin/cloudflare/purge_cache | Purge all domain caches | none | admin |

> Source of truth: `config/routes.rb`

### Cloudflare API Request
```json
{
  "purge_everything": true
}
```
**Endpoint:** `POST https://api.cloudflare.com/client/v4/zones/{zone_id}/purge_cache`
**Auth:** `Authorization: Bearer {api_token}`

### Cloudflare API Response (success)
```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": {
    "id": "purge_id_string"
  }
}
```

### Error Response
```json
{
  "success": false,
  "errors": [
    { "code": 10000, "message": "Authentication error" }
  ]
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- User is authenticated as admin (not editor)
- `CLOUDFLARE_CACHE_PURGE_TOKEN` environment variable is set
- At least one `{DOMAIN}_CLOUDFLARE_ZONE_ID` is configured

**Postconditions:**
- Cache purge request sent to Cloudflare for each configured zone
- Flash message displayed indicating success/failure per zone
- Purge action logged with user, timestamp, and zones

**Edge cases & failure modes:**
- Missing API token: Configuration error, clear message to user
- Missing zone ID for a domain: Skip that domain, purge others
- Partial failure (some zones succeed, some fail): Show mixed success/failure message
- Rate limit (429): Show rate limit error, suggest waiting
- Network timeout: Retry once, then show timeout error

### Non-Functionals
- **Performance**: Sequential zone purging (max 4 zones), ~1-4 seconds total
- **Rate limits**: Cloudflare free tier allows 5 purge_everything requests/minute
- **Security**: Admin-only access, CSRF protection, API token never exposed
- **Logging**: All purge attempts logged with user, zones, and result

## Acceptance Criteria
- [ ] Admin users can access "Purge Cache" button in sidebar under Global section
- [ ] Non-admin users (editors) cannot see or access the purge endpoint
- [ ] Clicking button shows confirmation dialog: "Purge cache for all domains?"
- [ ] Successful purge shows flash message: "Cache purged successfully for: music, movies, games, books"
- [ ] Partial failure shows warning: "Cache purged for: music, movies. Failed for: games (timeout)"
- [ ] Configuration error shows clear message: "CLOUDFLARE_CACHE_PURGE_TOKEN not configured"
- [ ] Rate limit error (429) handled gracefully with user-friendly message
- [ ] Purge action logged to Rails.logger with user email, timestamp, and results
- [ ] Uses Bearer token authentication (not legacy X-Auth-Key)

### Golden Examples

**Successful purge:**
```text
Input: Admin clicks "Purge Cache" button and confirms
Action: POST /admin/cloudflare/purge_cache
Output: Flash success - "Cache purged successfully for: music, movies, games, books"
Log: "[Cloudflare] User admin@example.com purged cache for zones: music, movies, games, books"
```

**Partial failure:**
```text
Input: Admin purges, but games zone times out
Output: Flash warning - "Cache purged for: music, movies, books. Failed for: games (Request timed out)"
Log: "[Cloudflare] Partial purge - success: music, movies, books; failed: games"
```

**Configuration error:**
```text
Input: CLOUDFLARE_CACHE_PURGE_TOKEN not set
Output: Flash error - "Cloudflare configuration error: CLOUDFLARE_CACHE_PURGE_TOKEN cannot be blank"
```

---

## Agent Hand-Off

### Constraints
- Follow existing project patterns; do not introduce new architecture.
- Model HTTP client after `app/lib/music/musicbrainz/base_client.rb`.
- Model exceptions after `app/lib/music/musicbrainz/exceptions.rb`.
- Respect snippet budget (≤40 lines per block).
- Do not duplicate authoritative code; **link to file paths**.

### Required Outputs
- Updated files (paths listed in "Key Files Touched").
- Passing tests demonstrating Acceptance Criteria.
- Updated: "Implementation Notes", "Deviations", "Documentation Updated".

### Sub-Agent Plan
1) codebase-pattern-finder → examine MusicBrainz client patterns at `app/lib/music/musicbrainz/`
2) codebase-analyzer → verify admin controller authentication and flash patterns
3) web-search-researcher → not needed (Cloudflare API research complete)
4) technical-writer → update docs and .env.example after implementation

### Test Seed / Fixtures
- No database fixtures needed
- Use WebMock to stub Cloudflare API responses
- Test scenarios: success, auth error (401/403), rate limit (429), timeout

---

## Implementation Notes (living)

### Approach
Create `app/lib/cloudflare/` module following MusicBrainz client patterns:
1. `configuration.rb` - Load env vars, validate, provide zone ID accessors
2. `exceptions.rb` - Hierarchy of error types (ConfigurationError, NetworkError, HttpError, etc.)
3. `base_client.rb` - Faraday HTTP client with Bearer auth, error mapping
4. `purge_service.rb` - Business logic for multi-zone purging

### Key Files Touched (paths only)
- `app/lib/cloudflare/configuration.rb` (new)
- `app/lib/cloudflare/exceptions.rb` (new)
- `app/lib/cloudflare/base_client.rb` (new)
- `app/lib/cloudflare/purge_service.rb` (new)
- `app/controllers/admin/cloudflare_controller.rb` (new)
- `config/routes.rb` (add route in admin namespace)
- `app/views/admin/shared/_sidebar.html.erb` (add button)
- `.env.example` (add zone ID env vars)
- `test/lib/cloudflare/*_test.rb` (new tests)
- `test/controllers/admin/cloudflare_controller_test.rb` (new)

### Environment Variables
```bash
# Cloudflare Cache Purging
CLOUDFLARE_CACHE_PURGE_TOKEN=cf_xxx          # API token with Zone.Cache Purge permission
MUSIC_CLOUDFLARE_ZONE_ID=xxx         # Zone ID for thegreatestmusic.org
MOVIES_CLOUDFLARE_ZONE_ID=xxx        # Zone ID for thegreatestmovies.org
GAMES_CLOUDFLARE_ZONE_ID=xxx         # Zone ID for thegreatest.games
BOOKS_CLOUDFLARE_ZONE_ID=xxx         # Zone ID for thegreatestbooks.org
```

**Security Note:** Zone IDs are not secrets (like usernames), but stored in env vars for configurability. The API token IS a secret and must never be committed.

### Reference Snippets (≤40 lines, non-authoritative)

**Configuration:**
```ruby
# app/lib/cloudflare/configuration.rb - reference only
module Cloudflare
  class Configuration
    DOMAINS = [:music, :movies, :games, :books].freeze

    def zone_id(domain)
      ENV.fetch("#{domain.upcase}_CLOUDFLARE_ZONE_ID")
    end

    def api_token
      ENV.fetch("CLOUDFLARE_CACHE_PURGE_TOKEN")
    end
  end
end
```

**Purge Service:**
```ruby
# app/lib/cloudflare/purge_service.rb - reference only
module Cloudflare
  class PurgeService
    def purge_all_zones
      results = {}
      Configuration::DOMAINS.each do |domain|
        results[domain] = purge_zone(domain)
      rescue => e
        results[domain] = { success: false, error: e.message }
      end
      { success: results.values.all? { |r| r[:success] }, results: results }
    end
  end
end
```

**Controller:**
```ruby
# app/controllers/admin/cloudflare_controller.rb - reference only
class Admin::CloudflareController < Admin::BaseController
  before_action :require_admin_role!

  def purge_cache
    result = Cloudflare::PurgeService.new.purge_all_zones
    flash[result[:success] ? :success : :warning] = format_message(result)
    redirect_back(fallback_location: admin_root_path)
  end
end
```

**Route:**
```ruby
# config/routes.rb - add in namespace :admin block
resource :cloudflare, only: [] do
  post :purge_cache
end
```

**Sidebar button:**
```erb
<!-- app/views/admin/shared/_sidebar.html.erb - add in Global section -->
<li>
  <%= button_to admin_cloudflare_purge_cache_path, method: :post,
      class: "flex items-center gap-2",
      form: { data: { turbo_confirm: "Purge cache for all domains?" } } do %>
    <!-- refresh icon SVG -->
    Purge Cache
  <% end %>
</li>
```

### Challenges & Resolutions
- Route helper naming: Rails generates `purge_cache_admin_cloudflare_path` (not `admin_cloudflare_purge_cache_path`). Fixed in sidebar.
- Configuration validation: Made zone IDs optional (app can work with partial configuration), only API token is required.

### Deviations From Plan
- None significant. Implementation follows the spec closely.

## Acceptance Results
- Date: 2026-01-17
- Verifier: Claude
- Artifacts:
  - Route verified: `bin/rails routes -g cloudflare` shows `POST /admin/cloudflare/purge_cache`
  - All files pass syntax check
  - Rails app boots successfully with new code

## Future Improvements
- Selective URL purging for specific pages
- Automatic cache purging after model updates (via ActiveJob)
- Cache tag purging (requires Cloudflare Enterprise)
- Per-domain purge buttons (instead of purging all)
- Purge history/audit log in database

## Related PRs
- #...

## Documentation Updated
- [x] `documentation.md` - no changes needed (general guide)
- [x] Class docs:
  - `docs/lib/cloudflare/configuration.md`
  - `docs/lib/cloudflare/exceptions.md`
  - `docs/lib/cloudflare/base_client.md`
  - `docs/lib/cloudflare/purge_service.md`
  - `docs/controllers/admin/cloudflare_controller.md`
- [x] `.env.example` - added Cloudflare zone ID variables
