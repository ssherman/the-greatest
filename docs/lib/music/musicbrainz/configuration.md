# Music::Musicbrainz::Configuration

## Summary
Manages configuration settings for the MusicBrainz API client, including URL, timeouts, and user agent settings.

## Public Methods

### `#api_url`
Returns the full API URL for MusicBrainz requests
- Returns: String - The complete API URL

### `#base_url`
Returns the base URL from environment or default
- Returns: String - The base URL for MusicBrainz

### `#user_agent`
Returns the user agent string for API requests
- Returns: String - User agent string

### `#timeout`
Returns the request timeout in seconds
- Returns: Integer - Timeout value in seconds

### `#open_timeout`
Returns the connection open timeout in seconds
- Returns: Integer - Open timeout value in seconds

### `#validate_configuration!`
Validates the configuration settings
- Raises: ArgumentError - If MUSICBRAINZ_URL is invalid or blank

## Constants
- `DEFAULT_URL` - Default MusicBrainz API URL ("https://musicbrainz.org")
- `DEFAULT_USER_AGENT` - Default user agent string
- `DEFAULT_TIMEOUT` - Default request timeout (30 seconds)
- `DEFAULT_OPEN_TIMEOUT` - Default connection timeout (10 seconds)

## Dependencies
- Environment variable `MUSICBRAINZ_URL` for custom API endpoint
- URI parsing for URL validation

## Usage
```ruby
config = Music::Musicbrainz::Configuration.new
config.validate_configuration!
client = Music::Musicbrainz::BaseClient.new(config)
``` 