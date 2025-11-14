# Admin::Music::ListsHelper

## Summary
Helper methods for admin list views. Provides utilities for counting items in JSON data and converting JSON objects to display strings.

## Public Methods

### `#count_items_json(items_json)`
Counts the number of items in a list's items_json field, handling multiple formats.

**Parameters:**
- `items_json` (Hash, Array, String, nil) - The items_json field from a list

**Returns:** Integer - The count of items

**Behavior:**
- **Hash format**: Finds first Array value (e.g., `{"albums": [...]}` or `{"songs": [...]}`) and returns its length
- **Array format**: Returns array length
- **String format**: Attempts to parse as JSON first, then counts
- **Invalid JSON string**: Returns 0
- **Nil/empty**: Returns 0
- **Other types**: Returns 0

**Examples:**
```ruby
# Hash format
count_items_json({"albums" => [{...}, {...}]})  # => 2

# Array format
count_items_json([{...}, {...}, {...}])  # => 3

# JSON string (auto-parsed)
count_items_json('{"albums": [{...}]}')  # => 1

# Invalid
count_items_json(nil)  # => 0
count_items_json('invalid json')  # => 0
```

**Usage in views:**
```erb
<%= pluralize(count_items_json(@list.items_json), "item") %>
```

### `#items_json_to_string(items_json)`
Converts items_json to a pretty-printed JSON string for editing in textareas.

**Parameters:**
- `items_json` (Hash, Array, String, nil) - The items_json field from a list

**Returns:** String, nil - Pretty-printed JSON string or the original string

**Behavior:**
- **Hash or Array**: Converts to pretty JSON with indentation
- **String**: Returns as-is (already a string)
- **Nil or empty**: Returns nil

**Examples:**
```ruby
# Hash to pretty JSON
items_json_to_string({"albums" => [{"rank" => 1}]})
# => "{\n  \"albums\": [\n    {\n      \"rank\": 1\n    }\n  ]\n}"

# String returned as-is
items_json_to_string('{"albums": [...]}')  # => '{"albums": [...]}'

# Nil handling
items_json_to_string(nil)  # => nil
```

**Usage in views:**
```erb
<%= f.text_area :items_json, value: items_json_to_string(@list.items_json) %>
```

## Design Rationale

### Why handle strings?
PostgreSQL JSONB columns can store both proper JSON objects (Hash/Array) AND JSON strings. The helpers need to gracefully handle both:
- **New saves**: Controller parses strings to objects before saving
- **Old data**: May still exist as strings in database (test data)
- **Display**: Works seamlessly regardless of storage format

### Why auto-parse in count_items_json?
Provides resilience against inconsistent data storage. If items_json is stored as a string (from direct model updates), the helper still returns correct counts on the show page.

### Why not parse in items_json_to_string?
Strings are already in the correct format for textareas. Parsing and re-stringifying would be unnecessary work.

## Testing
See `test/helpers/admin/music/lists_helper_test.rb` for comprehensive test coverage:
- 18 tests covering all formats and edge cases
- Validates Hash, Array, and String handling
- Tests nil, empty, and invalid inputs
- Verifies large counts (1000+ items)

## Dependencies
- JSON module for parsing

## Related Files
- Controller: `app/controllers/admin/music/lists_controller.rb`
- Views: `app/views/admin/music/albums/lists/`
- Tests: `test/helpers/admin/music/lists_helper_test.rb`
