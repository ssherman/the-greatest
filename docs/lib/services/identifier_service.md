# IdentifierService

## Summary
Service object responsible for all identifier-related business logic. Provides methods for adding, finding, and managing identifiers across different media domains. Optimized for data import and deduplication workflows.

## Public Methods

### `self.add_identifier(identifiable, type, value)`
Creates and saves an identifier for the given object
- **Parameters**: 
  - `identifiable` (ActiveRecord::Base) - The object to add the identifier to
  - `type` (String/Symbol) - The identifier type enum value
  - `value` (String) - The identifier value
- **Returns**: `Result` struct with `success?`, `data` (Identifier), and `errors`
- **Side Effects**: Creates new Identifier record, strips whitespace from value
- **Example**:
  ```ruby
  result = IdentifierService.add_identifier(artist, :music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")
  if result.success?
    puts "Identifier added: #{result.data.value}"
  else
    puts "Error: #{result.errors}"
  end
  ```

### `self.find_by_identifier(type, value)`
Finds an object by a specific identifier type and value
- **Parameters**:
  - `type` (String/Symbol) - The identifier type enum value
  - `value` (String) - The identifier value to search for
- **Returns**: The identifiable object (e.g., Music::Artist) or `nil` if not found
- **Side Effects**: Strips whitespace from value before searching
- **Example**:
  ```ruby
  artist = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")
  puts artist.name if artist
  ```

### `self.find_by_identifier_in_domain(identifiable_type, type, value)`
Finds an object by identifier within a specified domain
- **Parameters**:
  - `identifiable_type` (String) - The class name (e.g., "Music::Artist")
  - `type` (String/Symbol) - The identifier type enum value
  - `value` (String) - The identifier value to search for
- **Returns**: The identifiable object or `nil` if not found
- **Side Effects**: Strips whitespace from value before searching
- **Example**:
  ```ruby
  artist = IdentifierService.find_by_identifier_in_domain("Music::Artist", :music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")
  ```

### `self.find_by_value_in_domain(identifiable_type, value)`
Finds an object by value only within a domain (useful for ISBN/EAN use cases)
- **Parameters**:
  - `identifiable_type` (String) - The class name (e.g., "Books::Book")
  - `value` (String) - The identifier value to search for
- **Returns**: The identifiable object or `nil` if not found
- **Side Effects**: Strips whitespace from value before searching
- **Example**:
  ```ruby
  book = IdentifierService.find_by_value_in_domain("Books::Book", "9780140283334")
  # Will find book regardless of whether it's stored as ISBN-10 or ISBN-13
  ```

### `self.resolve_identifiers(identifiable)`
Retrieves all identifiers associated with a given object
- **Parameters**:
  - `identifiable` (ActiveRecord::Base) - The object to get identifiers for
- **Returns**: Array of Identifier objects, ordered by `identifier_type`
- **Example**:
  ```ruby
  identifiers = IdentifierService.resolve_identifiers(artist)
  identifiers.each { |id| puts "#{id.identifier_type}: #{id.value}" }
  ```

### `self.identifier_exists?(type, value)`
Checks if a specific identifier exists
- **Parameters**:
  - `type` (String/Symbol) - The identifier type enum value
  - `value` (String) - The identifier value to check
- **Returns**: Boolean indicating whether the identifier exists
- **Side Effects**: Strips whitespace from value before checking
- **Example**:
  ```ruby
  if IdentifierService.identifier_exists?(:music_musicbrainz_artist_id, "5441c29d-3602-4898-b1a1-b77fa23b8e50")
    puts "Artist already exists in database"
  end
  ```

## Result Structure
The service uses a `Result` struct for consistent responses:
```ruby
Result = Struct.new(:success?, :data, :errors, keyword_init: true)
```

- `success?` (Boolean) - Whether the operation succeeded
- `data` (Object) - The result data (Identifier object, identifiable object, etc.)
- `errors` (Array/String) - Error messages if operation failed

## Error Handling
- Invalid identifier types return `nil` for find methods
- Validation errors are captured in the `Result.errors` field
- Whitespace is automatically stripped from values
- Duplicate identifiers are prevented at the database level

## Performance Considerations
- Uses optimized database indexes for fast lookups
- Strips whitespace once per operation
- Leverages Rails enum handling for type conversion
- Polymorphic associations are handled efficiently by Rails

## Usage Patterns

### Data Import Workflow
```ruby
# Check if item already exists
existing_artist = IdentifierService.find_by_identifier(:music_musicbrainz_artist_id, mbid)
if existing_artist
  puts "Artist already exists: #{existing_artist.name}"
else
  # Create new artist and add identifier
  artist = Music::Artist.create!(name: "New Artist")
  result = IdentifierService.add_identifier(artist, :music_musicbrainz_artist_id, mbid)
  puts "Created new artist with identifier" if result.success?
end
```

### Cross-Domain Isolation
```ruby
# These will find different objects even with same identifier value
artist = IdentifierService.find_by_identifier_in_domain("Music::Artist", :music_asin, "B000001234")
album = IdentifierService.find_by_identifier_in_domain("Music::Album", :music_asin, "B000001234")
```

### ISBN/EAN Lookup
```ruby
# Find book by any ISBN format
book = IdentifierService.find_by_value_in_domain("Books::Book", "9780140283334")
# Will find the book whether it's stored as ISBN-10 or ISBN-13
```

## Dependencies
- `Identifier` model
- Rails polymorphic associations
- PostgreSQL for optimized queries

## Related Models
- `Identifier` - The underlying model for identifier storage
- All identifiable models (Music::Artist, Music::Album, etc.) - Have `has_many :identifiers` associations 