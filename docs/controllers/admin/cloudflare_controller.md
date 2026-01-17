# Admin::CloudflareController

## Summary
Admin controller for Cloudflare cache management. Provides an endpoint to purge Cloudflare cache for a specific domain. Admin-only access (editors cannot access).

## Inheritance
- Inherits from: `Admin::BaseController`
- Layout: `music/admin`

## Authorization
- Requires admin role (via `before_action :require_admin_role!`)
- Editors and regular users are denied access

## Actions

### `POST #purge_cache`
Purges the Cloudflare cache for a specific domain.

**Route:** `POST /admin/cloudflare/purge_cache`

**Route Helper:** `purge_cache_admin_cloudflare_path`

**Parameters:**
| Param | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | String | Yes | Domain type: `music`, `movies`, `games`, or `books` |

**Responses:**
- Success: Redirects back with `flash[:success]` message
- Invalid type: Redirects back with `flash[:error]` message
- API failure: Redirects back with `flash[:error]` message
- Config error: Redirects back with `flash[:error]` message

**Example:**
```ruby
# From sidebar button
button_to purge_cache_admin_cloudflare_path(type: :music), method: :post
```

## Flash Messages

| Scenario | Flash Type | Message Pattern |
|----------|------------|-----------------|
| Success | `:success` | "Cache purged successfully for {domain}" |
| Invalid type | `:error` | "Invalid domain type: {type}" |
| API failure | `:error` | "Failed to purge {domain} cache: {error}" |
| Config error | `:error` | "Cloudflare configuration error: {message}" |

## Logging
All purge actions are logged with:
- User email
- Status (success/failed)
- Affected domains

Format: `[Cloudflare] Purge action by {email}: status={status}, successful={domains}, failed={domains}`

## UI Integration
The purge button is located in the admin sidebar under the "Global" section. It is only visible to admin users (not editors).

## Dependencies
- `Cloudflare::PurgeService` - Business logic for cache purging
- `Cloudflare::Configuration` - Domain validation
- `Cloudflare::Exceptions` - Error handling

## Related Classes
- `Cloudflare::PurgeService` - Called to perform the purge
- `Admin::BaseController` - Parent class providing authentication
