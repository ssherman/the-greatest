# Services::Text::QuoteNormalizer

**Location:** `app/lib/services/text/quote_normalizer.rb`
**Type:** Shared Service (usable across all domains: Books, Music, Movies, Games)
**Purpose:** Normalize Unicode smart/curly quotes to ASCII straight quotes for consistent text representation

## Overview

`Services::Text::QuoteNormalizer` is a shared utility service that converts Unicode smart quotes (curly quotes) to their ASCII straight quote equivalents. This ensures consistent text representation across the application, improving duplicate detection, search matching, and data quality.

## Why This Service Exists

Different data sources (APIs, user input, imports) may use different quote character encodings:
- **Smart/Curly Quotes** (Unicode): ', ', ", "
- **Straight Quotes** (ASCII): ', "

Without normalization, identical content with different quote styles creates:
1. Duplicate records (e.g., "Don't" vs "Don't")
2. Failed search matches
3. Data quality issues
4. Import failures

## Usage

### Basic Usage

```ruby
# Normalize a string with smart quotes
normalized = Services::Text::QuoteNormalizer.call("Don't Stop Believin'")
# => "Don't Stop Believin'"

# Normalize double quotes
normalized = Services::Text::QuoteNormalizer.call(""The Wall"")
# => "\"The Wall\""

# Handle nil and empty strings
Services::Text::QuoteNormalizer.call(nil)  # => nil
Services::Text::QuoteNormalizer.call("")   # => ""
```

### Integration with Models

This service is automatically used in Music domain models via `before_validation` callbacks:

```ruby
# In Music::Song, Music::Album, Music::Artist
before_validation :normalize_title  # or :normalize_name

private

def normalize_title
  self.title = Services::Text::QuoteNormalizer.call(title) if title.present?
end
```

### Integration with Search

The service is integrated into search normalization:

```ruby
# In Search::Shared::Utils
def normalize_search_text(text)
  normalized = Services::Text::QuoteNormalizer.call(text.to_s)
  # ... additional normalization
end
```

## Public API

### `.call(text)` (Class Method)

Normalizes quote characters in the provided text.

**Parameters:**
- `text` (String, nil) - The text to normalize

**Returns:**
- `nil` if input is `nil`
- `""` if input is empty string
- Normalized string with all smart quotes converted to straight quotes

**Quote Mappings:**
- Left single quote (`\u2018` ') → Straight apostrophe (`\u0027` ')
- Right single quote (`\u2019` ') → Straight apostrophe (`\u0027` ')
- Left double quote (`\u201C` ") → Straight quote (`\u0022` ")
- Right double quote (`\u201D` ") → Straight quote (`\u0022` ")

## Implementation Details

### Character Constants

The service uses explicit Unicode character codes for reliability:

```ruby
LEFT_SINGLE_QUOTE = "\u2018"   # '
RIGHT_SINGLE_QUOTE = "\u2019"  # '
LEFT_DOUBLE_QUOTE = "\u201C"   # "
RIGHT_DOUBLE_QUOTE = "\u201D"  # "
STRAIGHT_APOSTROPHE = "\u0027" # '
STRAIGHT_QUOTE = "\u0022"      # "
```

### Normalization Process

1. Return `nil` if input is `nil`
2. Return `""` if input is empty
3. Replace all smart quote variants with straight quotes using `String#gsub`
4. Return normalized string

## Testing

Comprehensive test coverage in `test/lib/services/text/quote_normalizer_test.rb`:

```ruby
test ".call normalizes smart quotes to straight quotes" do
  text = "'Don't Stop Believin'""
  assert_equal "\"Don't Stop Believin'\"", QuoteNormalizer.call(text)
end
```

## Domain Usage

### Music Domain
- **Models:** `Music::Song`, `Music::Album`, `Music::Artist`
- **Fields:** `title` (Song, Album), `name` (Artist)
- **Integration:** `before_validation` callbacks

### Future Extensions
This shared service can be easily extended to other domains:
- **Books:** `Books::Book#title`, `Books::Author#name`
- **Movies:** `Movies::Movie#title`, `Movies::Director#name`
- **Games:** `Games::Game#title`, `Games::Developer#name`

## Performance Considerations

- **Time Complexity:** O(n) where n is the length of the input string
- **Memory:** Creates a new string (does not modify in place)
- **Efficiency:** Uses simple string replacement - very fast for typical title/name lengths

## Related Components

- **Models:** `Music::Song`, `Music::Album`, `Music::Artist` (uses via callbacks)
- **Search:** `Search::Shared::Utils` (uses for query normalization)
- **Tasks:** `music:normalize_names` rake task (bulk normalization)

## Examples

### Common Use Cases

```ruby
# Song titles
Services::Text::QuoteNormalizer.call("Don't Stop Believin'")
# => "Don't Stop Believin'"

# Album titles
Services::Text::QuoteNormalizer.call(""The Dark Side of the Moon"")
# => "\"The Dark Side of the Moon\""

# Artist names
Services::Text::QuoteNormalizer.call("Guns N' Roses")
# => "Guns N' Roses"

# Mixed quotes
Services::Text::QuoteNormalizer.call("'The "Greatest" Album'")
# => "'The \"Greatest\" Album'"
```

### Edge Cases

```ruby
# Already normalized - no change
Services::Text::QuoteNormalizer.call("Don't Stop")
# => "Don't Stop"

# Empty input
Services::Text::QuoteNormalizer.call("")
# => ""

# Nil input
Services::Text::QuoteNormalizer.call(nil)
# => nil

# No quotes
Services::Text::QuoteNormalizer.call("Hello World")
# => "Hello World"
```

## Design Decisions

### Why Normalize to ASCII Straight Quotes?

1. **Simplicity:** ASCII is simpler and more portable
2. **User Input:** Matches most keyboard defaults
3. **Portability:** Works across all systems and databases
4. **Convention:** Standard in most technical contexts
5. **Semantics:** Smart quotes are stylistic, not semantic

### Why a Shared Service (Not Domain-Specific)?

1. **Reusability:** Quote normalization applies to all domains
2. **Single Responsibility:** Focused on text normalization only
3. **Testability:** Easy to test in isolation
4. **Maintainability:** One place to update normalization logic
5. **Consistency:** Same normalization rules across all domains

### Why Service Pattern (Not Model Method or Concern)?

1. **Separation of Concerns:** Text normalization is not domain logic
2. **Reusability:** Usable outside model context (search, imports, etc.)
3. **Testability:** No dependency on ActiveRecord
4. **Performance:** Lightweight, stateless class method

## Maintenance Notes

### Adding New Quote Types

To normalize additional Unicode quote variants:

1. Add character constant at class level
2. Add corresponding `.gsub` call in `.call` method
3. Add test case in `quote_normalizer_test.rb`

### Extending to Other Punctuation

This pattern can be extended to normalize:
- Em dashes (—) → En dashes (–) or hyphens (-)
- Ellipses (…) → Three periods (...)
- Other Unicode punctuation variations

## Migration

To normalize existing data, use the rake task:

```bash
# Preview changes without modifying data
rails music:normalize_names DRY_RUN=true

# Apply normalization to all existing records
rails music:normalize_names
```

## Related Documentation

- [Music::Song Model](../../../models/music/song.md)
- [Music::Album Model](../../../models/music/album.md)
- [Music::Artist Model](../../../models/music/artist.md)
- [Search::Shared::Utils](../../search/shared/utils.md)
- [TODO: Name/Title Quote Normalization](../../../todos/071-music-name-title-normalization.md)
