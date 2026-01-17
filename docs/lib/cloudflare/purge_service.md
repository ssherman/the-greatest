# Cloudflare::PurgeService

## Summary
Service for purging Cloudflare cache. Supports purging individual zones or all configured zones with partial failure handling.

## Attributes

### `client`
- Type: `Cloudflare::BaseClient`
- HTTP client for API requests

### `config`
- Type: `Cloudflare::Configuration`
- Configuration with zone IDs

## Public Methods

### `#initialize(client: nil, config: nil)`
Creates a new service instance.
- Parameters:
  - `client` (Cloudflare::BaseClient, optional) - Client instance for dependency injection
  - `config` (Cloudflare::Configuration, optional) - Configuration instance
- Returns: PurgeService instance

### `#purge_all_zones`
Purges cache for all configured zones.
- Returns: Hash with keys:
  - `:success` (Boolean) - True if all zones purged successfully
  - `:results` (Hash) - Per-zone results (see below)
  - `:error` (String, optional) - Error message if no zones configured

### `#purge_zones(domains)`
Purges cache for specific domains.
- Parameters: `domains` (Array<Symbol>) - List of domains (e.g., `[:music, :movies]`)
- Returns: Hash with keys:
  - `:success` (Boolean) - True if all requested zones purged successfully
  - `:results` (Hash) - Per-zone results keyed by domain symbol

## Result Format

Per-zone results have this structure:

**Success:**
```ruby
{
  music: {
    success: true,
    purge_id: "abc123",
    response_time: 0.234
  }
}
```

**Failure:**
```ruby
{
  music: {
    success: false,
    error: "Authentication failed"
  }
}
```

## Partial Failure Handling
The service continues processing remaining zones even if one fails. The overall `:success` is only true if ALL zones succeed.

## Logging
- Success: `[Cloudflare] Successfully purged cache for {domain} (zone: {zone_id}...)`
- Failure: `[Cloudflare] Failed to purge cache for {domain}: {error}`

## Usage Examples

```ruby
# Purge single zone
service = Cloudflare::PurgeService.new
result = service.purge_zones([:music])

if result[:success]
  puts "Purged: #{result[:results][:music][:purge_id]}"
else
  puts "Failed: #{result[:results][:music][:error]}"
end

# Purge all configured zones
result = service.purge_all_zones
successful = result[:results].select { |_, v| v[:success] }.keys
failed = result[:results].reject { |_, v| v[:success] }.keys
```

## Dependencies
- `Cloudflare::BaseClient` - HTTP requests
- `Cloudflare::Configuration` - Zone ID lookups
- `Cloudflare::Exceptions` - Error handling

## Related Classes
- `Admin::CloudflareController` - Primary consumer via admin UI
