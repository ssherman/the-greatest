# DataImporters::Music::Artist::ImportQuery

## Summary
Query object for Music::Artist imports with validation and parameter handling. Ensures type-safe input for artist import operations.

## Public Methods

### `.new(name:, **options)`
Constructor for artist import queries
- Parameters:
  - name (String) - Artist name to import (required)
  - options (Hash) - Additional import options (optional)
- Purpose: Creates validated query object for artist import

### `#valid?`
Validates query parameters
- Returns: Boolean - True if query has valid parameters
- Validation rules: Name must be present (not nil, empty, or whitespace-only)

### `#to_h`
Converts query to hash representation
- Returns: Hash with :name and :options keys
- Purpose: Serialization and debugging support

## Attributes
- `name` (String) - Artist name to search for and import
- `options` (Hash) - Additional parameters and import preferences

## Validation Rules

### Required Parameters
- **name**: Must be present and not blank
  - Cannot be nil
  - Cannot be empty string
  - Cannot be whitespace-only

### Optional Parameters
All additional parameters are stored in options hash and can include:
- **country** - ISO country code hint
- **year_formed** - Formation year for disambiguation  
- **force_update** - Override existing data
- **provider_preferences** - Specify which external sources to use

## Usage Examples

### Basic Query
```ruby
query = DataImporters::Music::Artist::ImportQuery.new(name: "Pink Floyd")
puts query.valid?  # => true
puts query.name    # => "Pink Floyd"
puts query.options # => {}
```

### Query with Options
```ruby
query = DataImporters::Music::Artist::ImportQuery.new(
  name: "Pink Floyd",
  country: "GB",
  year_formed: 1965,
  force_update: true
)

puts query.valid?  # => true
puts query.options # => {country: "GB", year_formed: 1965, force_update: true}
```

### Invalid Query
```ruby
query = DataImporters::Music::Artist::ImportQuery.new(name: "")
puts query.valid?  # => false

query = DataImporters::Music::Artist::ImportQuery.new(name: nil)
puts query.valid?  # => false

query = DataImporters::Music::Artist::ImportQuery.new(name: "   ")
puts query.valid?  # => false
```

## Serialization
```ruby
query = DataImporters::Music::Artist::ImportQuery.new(
  name: "David Bowie", 
  country: "GB"
)

hash = query.to_h
# => {
#   name: "David Bowie",
#   options: {country: "GB"}
# }
```

## Integration
Used by DataImporters::Music::Artist::Importer:
```ruby
# Importer creates query internally
result = DataImporters::Music::Artist::Importer.call(name: "Pink Floyd")

# Or create explicitly for validation
query = DataImporters::Music::Artist::ImportQuery.new(name: user_input)
if query.valid?
  result = DataImporters::Music::Artist::Importer.call(query: query)
else
  puts "Invalid artist name"
end
```

## Dependencies
- Rails validation helpers (present? method)
- Base ImportQuery class
- Used by Importer and Finder classes