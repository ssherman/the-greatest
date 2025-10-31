# DataImporters::FinderBase

## Summary
Abstract base class for finding existing records before import using external identifiers. Provides a common interface and helper methods for subclasses that implement domain-specific finding logic. Used throughout the data import system to prevent duplicate records.

## Overview
The FinderBase class serves as a foundation for finder classes in the data import pipeline. Before importing a new record from an external source (like MusicBrainz), the system first attempts to find an existing record using external identifiers (ISBNs, MusicBrainz IDs, IMDB IDs, etc.).

This class provides:
- Abstract interface that subclasses must implement
- Helper method for identifier-based lookups with N+1 query prevention
- Consistent pattern across all domain finders

## Class Hierarchy

```
DataImporters::FinderBase (abstract)
  └── DataImporters::Music::Song::Finder
  └── DataImporters::Books::Book::Finder
  └── DataImporters::Movies::Movie::Finder
  └── (other domain-specific finders)
```

## Public Methods

### `#call(query:)`
Abstract method that must be implemented by subclasses.

- **Parameters**:
  - `query` - Domain-specific query object containing search criteria
- **Returns**: Model instance if found, nil otherwise
- **Raises**: `NotImplementedError` if called on base class
- **Implementation Required**: Subclasses must override this method

**Example Implementation**:
```ruby
class DataImporters::Music::Song::Finder < DataImporters::FinderBase
  def call(query:)
    # Try MusicBrainz ID first
    if query.musicbrainz_recording_id.present?
      found = find_by_identifier(
        identifier_type: 'musicbrainz_recording',
        identifier_value: query.musicbrainz_recording_id,
        model_class: ::Music::Song
      )
      return found if found
    end

    # Fall back to other search strategies
    nil
  end
end
```

## Protected Methods

### `#find_by_identifier(identifier_type:, identifier_value:, model_class:)`
Finds an existing record using an external identifier with optimized database queries.

- **Parameters**:
  - `identifier_type` (String) - Type of identifier (e.g., 'musicbrainz_recording', 'isbn', 'imdb_id')
  - `identifier_value` (String) - The identifier value to search for
  - `model_class` (Class) - The model class to find (e.g., `::Music::Song`)
- **Returns**: Model instance if found, nil otherwise
- **Performance**: Uses `.includes(:identifiable)` to prevent N+1 queries when accessing the associated record

**Implementation Details**:
```ruby
def find_by_identifier(identifier_type:, identifier_value:, model_class:)
  identifier = Identifier.includes(:identifiable).find_by(
    identifier_type: identifier_type,
    value: identifier_value,
    identifiable_type: model_class.name
  )

  identifier&.identifiable
end
```

The `.includes(:identifiable)` is critical for performance:
- Without it: N+1 query when accessing `identifier.identifiable`
- With it: Single joined query loads both identifier and associated record

## Usage Patterns

### Typical Finder Implementation

```ruby
class DataImporters::Music::Song::Finder < DataImporters::FinderBase
  def call(query:)
    # Strategy 1: External identifier (preferred)
    if query.musicbrainz_recording_id.present?
      found = find_by_identifier(
        identifier_type: 'musicbrainz_recording',
        identifier_value: query.musicbrainz_recording_id,
        model_class: ::Music::Song
      )
      return found if found
    end

    # Strategy 2: Fuzzy matching by title
    if query.title.present?
      found = find_by_fuzzy_title(query.title)
      return found if found
    end

    nil
  end

  private

  def find_by_fuzzy_title(title)
    # Domain-specific fuzzy matching logic
  end
end
```

### Integration with Importer

Finders are called early in the import process:

```ruby
class DataImporters::Music::Song::Importer < DataImporters::ImporterBase
  def call(query:)
    # Try to find existing record first
    existing = finder.call(query: query)
    return Result.success(item: existing) if existing

    # Only import if not found
    import_from_providers(query)
  end

  def finder
    @finder ||= DataImporters::Music::Song::Finder.new
  end
end
```

## Performance Considerations

### N+1 Query Prevention
The `.includes(:identifiable)` in `find_by_identifier` prevents a common N+1 query:

**Without includes (BAD)**:
```sql
-- Query 1: Find identifier
SELECT * FROM identifiers WHERE identifier_type = 'musicbrainz_recording' AND value = '...'

-- Query 2: Load associated record (N+1!)
SELECT * FROM songs WHERE id = 123
```

**With includes (GOOD)**:
```sql
-- Single query with join
SELECT identifiers.*, songs.*
FROM identifiers
LEFT OUTER JOIN songs ON songs.id = identifiers.identifiable_id
WHERE identifiers.identifier_type = 'musicbrainz_recording'
  AND identifiers.value = '...'
  AND identifiers.identifiable_type = 'Music::Song'
```

### Caching Strategies
Finders are instantiated once per import operation:
```ruby
def finder
  @finder ||= DataImporters::Music::Song::Finder.new
end
```

This allows subclasses to implement caching if needed:
```ruby
class MyFinder < FinderBase
  def initialize
    @cache = {}
  end

  def call(query:)
    @cache[query.id] ||= expensive_lookup(query)
  end
end
```

## Dependencies

### Direct Dependencies
- `Identifier` model - Stores external identifiers for polymorphic records
- Domain models (via `model_class` parameter) - The records being found

### Related Classes
- `DataImporters::ImporterBase` - Parent class for importers that use finders
- `DataImporters::ImportQuery` - Query objects passed to finders
- All domain-specific finder subclasses

## Subclass Responsibilities

When creating a new finder, subclasses must:

1. **Implement `#call(query:)`**:
   - Accept domain-specific query object
   - Return found record or nil
   - Try multiple finding strategies if appropriate

2. **Use Helper Methods**:
   - Call `find_by_identifier` for external ID lookups
   - Leverage polymorphic identifier system

3. **Handle Edge Cases**:
   - Null/empty query values
   - Multiple potential matches (return best match or nil)
   - Ambiguous data

4. **Document Finding Strategies**:
   - Order of precedence for different identifiers
   - Fuzzy matching algorithms used
   - Confidence thresholds

## Testing Approach

### Base Class Testing
```ruby
test "call raises NotImplementedError" do
  error = assert_raises(NotImplementedError) do
    DataImporters::FinderBase.new.call(query: double)
  end

  assert_match(/must implement/, error.message)
end
```

### Subclass Testing
Test each finding strategy:

```ruby
class DataImporters::Music::Song::FinderTest < ActiveSupport::TestCase
  test "finds existing song by musicbrainz_recording_id" do
    song = music_songs(:time)
    identifiers(:time_mb_recording)

    query = DataImporters::Music::Song::ImportQuery.new(
      musicbrainz_recording_id: 'mb-123'
    )
    result = DataImporters::Music::Song::Finder.new.call(query: query)

    assert_equal song, result
  end

  test "returns nil when not found" do
    query = DataImporters::Music::Song::ImportQuery.new(
      musicbrainz_recording_id: 'nonexistent'
    )
    result = DataImporters::Music::Song::Finder.new.call(query: query)

    assert_nil result
  end

  test "does not cause N+1 queries" do
    song = music_songs(:time)
    identifiers(:time_mb_recording)

    query = DataImporters::Music::Song::ImportQuery.new(
      musicbrainz_recording_id: 'mb-123'
    )

    assert_queries(1) do
      DataImporters::Music::Song::Finder.new.call(query: query)
    end
  end
end
```

### Integration Testing
Test with importer:

```ruby
test "prevents duplicate imports" do
  existing_song = music_songs(:time)
  identifiers(:time_mb_recording)

  result = DataImporters::Music::Song::Importer.call(
    musicbrainz_recording_id: 'mb-123'
  )

  assert result.success?
  assert_equal existing_song, result.item
  assert_equal 1, Music::Song.count
end
```

## Common Identifier Types

### Music Domain
- `musicbrainz_recording` - MusicBrainz recording ID
- `musicbrainz_artist` - MusicBrainz artist ID
- `spotify_track` - Spotify track ID
- `isrc` - International Standard Recording Code

### Books Domain
- `isbn` - International Standard Book Number
- `isbn13` - 13-digit ISBN
- `goodreads` - Goodreads book ID
- `google_books` - Google Books ID

### Movies Domain
- `imdb_id` - IMDB identifier
- `tmdb_id` - The Movie Database ID
- `rotten_tomatoes` - Rotten Tomatoes ID

### Games Domain
- `igdb` - IGDB game ID
- `steam` - Steam app ID
- `gog` - GOG game ID

## Error Handling

### Database Errors
```ruby
def find_by_identifier(identifier_type:, identifier_value:, model_class:)
  identifier = Identifier.includes(:identifiable).find_by(
    identifier_type: identifier_type,
    value: identifier_value,
    identifiable_type: model_class.name
  )

  identifier&.identifiable
rescue ActiveRecord::RecordNotFound
  # Shouldn't happen with find_by, but guard anyway
  nil
end
```

### Invalid Polymorphic Associations
If `identifiable_type` doesn't match `model_class`:
```ruby
# This is prevented by the WHERE clause
identifiable_type: model_class.name
```

## Best Practices

### Do
- Use `find_by_identifier` for all external ID lookups
- Try most specific identifiers first (external IDs before fuzzy matching)
- Return nil when no match found (don't raise exceptions)
- Document finding strategies in subclass comments
- Test performance to prevent N+1 queries

### Don't
- Don't create records in finders (that's the importer's job)
- Don't make external API calls in finders (use cached data only)
- Don't raise exceptions for not found (return nil)
- Don't modify the query object
- Don't return multiple results (pick best match or return nil)

## Related Documentation
- [Identifier](/home/shane/dev/the-greatest/docs/models/identifier.md) - External identifier model
- [DataImporters::ImporterBase](/home/shane/dev/the-greatest/docs/lib/data_importers/importer_base.md) - Base importer class
- [DataImporters::Music::Song::Finder](/home/shane/dev/the-greatest/docs/lib/data_importers/music/song/finder.md) - Example subclass
- [DataImporters::Music::Song::Importer](/home/shane/dev/the-greatest/docs/lib/data_importers/music/song/importer.md) - Example usage

## See Also
- Identifier system architecture in `docs/features/identifiers.md`
- Data import pipeline overview in `docs/features/data-import.md`
