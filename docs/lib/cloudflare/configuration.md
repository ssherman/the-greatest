# Cloudflare::Configuration

## Summary
Configuration class for Cloudflare API integration. Loads and validates environment variables for API authentication and zone IDs.

## Constants

### `API_BASE_URL`
- Value: `"https://api.cloudflare.com/client/v4"`
- The base URL for all Cloudflare API requests

### `DEFAULT_TIMEOUT`
- Value: `30` (seconds)
- Connection timeout for API requests

### `DEFAULT_OPEN_TIMEOUT`
- Value: `10` (seconds)
- Open connection timeout for API requests

### `DOMAINS`
- Value: `[:music, :movies, :games, :books]`
- List of supported domain types for cache purging

## Attributes

### `api_token`
- Type: String
- The Cloudflare API token for authentication (from `CLOUDFLARE_CACHE_PURGE_TOKEN` env var)

### `timeout`
- Type: Integer
- Request timeout in seconds (default: 30)

### `open_timeout`
- Type: Integer
- Open connection timeout in seconds (default: 10)

### `logger`
- Type: Logger
- Rails logger instance for request logging

## Public Methods

### `#api_url`
Returns the Cloudflare API base URL.
- Returns: String

### `#zone_id(domain)`
Returns the Cloudflare zone ID for a given domain.
- Parameters: `domain` (Symbol) - One of `:music`, `:movies`, `:games`, `:books`
- Returns: String or nil
- Raises: `Cloudflare::Exceptions::ZoneNotFoundError` if domain is not in `DOMAINS`

### `#configured_zones`
Returns a hash of all domains that have zone IDs configured.
- Returns: Hash with domain symbols as keys and zone IDs as values

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `CLOUDFLARE_CACHE_PURGE_TOKEN` | Yes | API token with Zone.Cache Purge permission |
| `MUSIC_CLOUDFLARE_ZONE_ID` | No | Zone ID for thegreatestmusic.org |
| `MOVIES_CLOUDFLARE_ZONE_ID` | No | Zone ID for thegreatestmovies.org |
| `GAMES_CLOUDFLARE_ZONE_ID` | No | Zone ID for thegreatest.games |
| `BOOKS_CLOUDFLARE_ZONE_ID` | No | Zone ID for thegreatestbooks.org |

## Validations
- Raises `Cloudflare::Exceptions::ConfigurationError` if `CLOUDFLARE_CACHE_PURGE_TOKEN` is missing or blank

## Dependencies
- `Cloudflare::Exceptions` - Custom exception classes

## Related Classes
- `Cloudflare::BaseClient` - Uses configuration for API requests
- `Cloudflare::PurgeService` - Uses configuration for zone lookups
