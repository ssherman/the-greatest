# Music::Musicbrainz::BaseClient

## Summary
Core HTTP client for making requests to the MusicBrainz API using Faraday, providing connection management, error handling, and response parsing.

## Public Methods

### `#initialize(config)`
Creates a new BaseClient instance
- Parameters: config (Music::Musicbrainz::Configuration) - Configuration settings
- Raises: Music::Musicbrainz::ConfigurationError - If configuration is invalid

### `#get(endpoint, params = {})`
Makes a GET request to the MusicBrainz API
- Parameters: 
  - endpoint (String) - API endpoint path
  - params (Hash) - Query parameters
- Returns: Hash - Structured response with success status, data, and metadata
- Raises: Music::Musicbrainz::NetworkError, Music::Musicbrainz::HttpError, Music::Musicbrainz::ParseError

## Private Methods

### `#connection`
Returns the configured Faraday connection
- Returns: Faraday::Connection - HTTP client connection

### `#build_params(params)`
Builds query parameters for the request
- Parameters: params (Hash) - Raw parameters
- Returns: Hash - Processed parameters

### `#parse_response(response, endpoint, params, start_time)`
Parses the API response into structured format
- Parameters:
  - response (Faraday::Response) - Raw HTTP response
  - endpoint (String) - API endpoint
  - params (Hash) - Request parameters
  - start_time (Time) - Request start time
- Returns: Hash - Structured response

### `#parse_success_response(response, endpoint, params, response_time)`
Parses successful API responses
- Parameters:
  - response (Faraday::Response) - Raw HTTP response
  - endpoint (String) - API endpoint
  - params (Hash) - Request parameters
  - response_time (Float) - Response time in seconds
- Returns: Hash - Success response structure

### `#parse_error_response(response, endpoint, params, response_time)`
Parses error API responses
- Parameters:
  - response (Faraday::Response) - Raw HTTP response
  - endpoint (String) - API endpoint
  - params (Hash) - Request parameters
  - response_time (Float) - Response time in seconds
- Returns: Hash - Error response structure

## Response Structure
```ruby
{
  success: true/false,
  data: {
    # Raw API response data
  },
  errors: ["Error message 1", "Error message 2"],
  metadata: {
    endpoint: "artist",
    query: "name:Beatles",
    response_time: 0.123
  }
}
```

## Dependencies
- Faraday gem for HTTP requests
- Music::Musicbrainz::Configuration for settings
- Music::Musicbrainz::Exceptions for error handling

## Usage
```ruby
config = Music::Musicbrainz::Configuration.new
client = Music::Musicbrainz::BaseClient.new(config)

# Make a search request
response = client.get("artist", { query: "name:Beatles" })

if response[:success]
  artists = response[:data]["artists"]
  puts "Found #{artists.length} artists"
else
  puts "Error: #{response[:errors].join(', ')}"
end
```

## Error Handling
- **Network Errors**: Timeouts, connection failures
- **HTTP Errors**: 4xx/5xx status codes with specific error types
- **Parse Errors**: Malformed JSON responses
- **Configuration Errors**: Invalid settings

## Performance Features
- **Connection Pooling**: Faraday handles connection reuse
- **Timeout Configuration**: Configurable request and connection timeouts
- **Response Timing**: Tracks response times for monitoring
- **Structured Logging**: Comprehensive request/response logging 