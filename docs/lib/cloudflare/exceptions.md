# Cloudflare::Exceptions

## Summary
Custom exception classes for Cloudflare API error handling. Provides a hierarchy of exceptions for different error types.

## Exception Hierarchy

```
Cloudflare::Exceptions::Error (base)
├── ConfigurationError
├── NetworkError
│   └── TimeoutError
├── HttpError
│   ├── AuthenticationError (401/403)
│   ├── RateLimitError (429)
│   └── ServerError (5xx)
└── ZoneNotFoundError
```

## Exception Classes

### `Error`
Base exception class for all Cloudflare errors.
- Inherits: `StandardError`

### `ConfigurationError`
Raised when configuration is invalid or missing.
- Inherits: `Error`
- Common causes: Missing `CLOUDFLARE_CACHE_PURGE_TOKEN`

### `NetworkError`
Raised for network-level errors (connection failures, etc).
- Inherits: `Error`
- Attributes:
  - `original_error` - The underlying Faraday exception

### `TimeoutError`
Raised when a request times out.
- Inherits: `NetworkError`

### `HttpError`
Base class for HTTP response errors.
- Inherits: `Error`
- Attributes:
  - `status_code` (Integer) - HTTP status code
  - `response_body` (String) - Raw response body

### `AuthenticationError`
Raised for 401/403 responses (invalid or expired token).
- Inherits: `HttpError`

### `RateLimitError`
Raised for 429 responses (rate limit exceeded).
- Inherits: `HttpError`

### `ServerError`
Raised for 5xx responses (Cloudflare server errors).
- Inherits: `HttpError`

### `ZoneNotFoundError`
Raised when an invalid domain is requested.
- Inherits: `Error`
- Attributes:
  - `domain` - The invalid domain that was requested

## Usage Examples

```ruby
begin
  service.purge_zones([:music])
rescue Cloudflare::Exceptions::AuthenticationError => e
  Rails.logger.error "Invalid API token: #{e.status_code}"
rescue Cloudflare::Exceptions::RateLimitError
  Rails.logger.warn "Rate limited, try again later"
rescue Cloudflare::Exceptions::NetworkError => e
  Rails.logger.error "Network error: #{e.message}"
end
```

## Related Classes
- `Cloudflare::BaseClient` - Raises these exceptions
- `Cloudflare::PurgeService` - Catches and handles these exceptions
