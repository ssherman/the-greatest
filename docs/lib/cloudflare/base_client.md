# Cloudflare::BaseClient

## Summary
HTTP client for Cloudflare API requests. Handles authentication, request/response formatting, and error mapping using Faraday.

## Attributes

### `config`
- Type: `Cloudflare::Configuration`
- Configuration instance with API token and settings

### `connection`
- Type: `Faraday::Connection`
- Pre-configured Faraday connection instance

## Public Methods

### `#initialize(config = nil)`
Creates a new client instance.
- Parameters: `config` (Cloudflare::Configuration, optional) - Configuration instance, creates new one if nil
- Returns: BaseClient instance

### `#post(endpoint, body:)`
Makes a POST request to the Cloudflare API.
- Parameters:
  - `endpoint` (String) - API endpoint path (e.g., `"zones/abc123/purge_cache"`)
  - `body` (Hash) - Request body to be JSON-encoded
- Returns: Hash with keys:
  - `:success` (Boolean) - Always true for successful responses
  - `:result` (Hash) - Parsed result from Cloudflare API
  - `:metadata` (Hash) - Request metadata including `:endpoint`, `:response_time`, `:status_code`
- Raises:
  - `Cloudflare::Exceptions::AuthenticationError` - 401/403 responses
  - `Cloudflare::Exceptions::RateLimitError` - 429 responses
  - `Cloudflare::Exceptions::ServerError` - 5xx responses
  - `Cloudflare::Exceptions::HttpError` - Other error responses or API `success: false`
  - `Cloudflare::Exceptions::TimeoutError` - Request timeout
  - `Cloudflare::Exceptions::NetworkError` - Connection failures

## Authentication
Uses Bearer token authentication via the `Authorization` header:
```
Authorization: Bearer <CLOUDFLARE_CACHE_PURGE_TOKEN>
```

## Request Format
- Content-Type: `application/json`
- Body: JSON-encoded hash

## Response Handling
Cloudflare API responses have the format:
```json
{
  "success": true,
  "result": { ... },
  "errors": [],
  "messages": []
}
```

The client validates `success: true` and raises `HttpError` if the API returns `success: false`.

## Dependencies
- `faraday` gem - HTTP client
- `Cloudflare::Configuration` - API settings
- `Cloudflare::Exceptions` - Error handling

## Related Classes
- `Cloudflare::PurgeService` - Primary consumer of this client
- `Cloudflare::Configuration` - Provides API token and settings
