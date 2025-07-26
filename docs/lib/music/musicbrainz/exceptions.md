# Music::Musicbrainz::Exceptions

## Summary
Defines a hierarchy of custom exception classes for MusicBrainz API errors, providing specific error types for better error handling and debugging.

## Exception Hierarchy

### `Music::Musicbrainz::Error`
Base exception class for all MusicBrainz-related errors
- **Purpose**: Root exception class for the MusicBrainz module
- **Usage**: Catch all MusicBrainz errors

### `Music::Musicbrainz::ConfigurationError`
Raised when configuration is invalid
- **Purpose**: Configuration validation failures
- **Common Causes**: Invalid MUSICBRAINZ_URL, missing required settings

### `Music::Musicbrainz::NetworkError`
Base class for network-related errors
- **Purpose**: Network connectivity issues
- **Subclasses**: TimeoutError

#### `Music::Musicbrainz::TimeoutError`
Raised when requests timeout
- **Purpose**: Request or connection timeouts
- **Common Causes**: Slow network, server overload

### `Music::Musicbrainz::HttpError`
Base class for HTTP response errors
- **Purpose**: HTTP status code errors
- **Subclasses**: ClientError, ServerError, NotFoundError, BadRequestError

#### `Music::Musicbrainz::ClientError`
Raised for 4xx HTTP status codes
- **Purpose**: Client-side errors (400-499)
- **Common Causes**: Invalid queries, authentication issues

#### `Music::Musicbrainz::ServerError`
Raised for 5xx HTTP status codes
- **Purpose**: Server-side errors (500-599)
- **Common Causes**: Server overload, maintenance

#### `Music::Musicbrainz::NotFoundError`
Raised for 404 HTTP status codes
- **Purpose**: Resource not found
- **Common Causes**: Invalid MBID, non-existent entity

#### `Music::Musicbrainz::BadRequestError`
Raised for 400 HTTP status codes
- **Purpose**: Invalid request parameters
- **Common Causes**: Malformed queries, invalid parameters

### `Music::Musicbrainz::ParseError`
Raised when JSON parsing fails
- **Purpose**: Response parsing errors
- **Common Causes**: Malformed JSON, unexpected response format

### `Music::Musicbrainz::QueryError`
Raised when search queries are invalid
- **Purpose**: Lucene query syntax errors
- **Common Causes**: Invalid field names, malformed Lucene syntax

## Usage
```ruby
begin
  results = search.search_by_name("Artist Name")
rescue Music::Musicbrainz::NetworkError => e
  # Handle network issues
  logger.error("Network error: #{e.message}")
rescue Music::Musicbrainz::NotFoundError => e
  # Handle not found
  logger.warn("Artist not found: #{e.message}")
rescue Music::Musicbrainz::QueryError => e
  # Handle invalid queries
  logger.error("Invalid query: #{e.message}")
rescue Music::Musicbrainz::Error => e
  # Handle any other MusicBrainz error
  logger.error("MusicBrainz error: #{e.message}")
end
```

## Error Handling Strategy
- **Graceful Degradation**: Search classes return structured error responses instead of raising exceptions
- **Detailed Logging**: Each exception includes context for debugging
- **User-Friendly Messages**: Clear error messages for end users
- **Recovery Options**: Network errors can be retried, query errors can be corrected 