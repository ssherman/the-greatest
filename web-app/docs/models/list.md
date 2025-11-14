# List Model

## Summary
Base model for all list types (albums, songs, etc.) using Single Table Inheritance (STI). Manages list metadata, status, and item relationships.

## Inheritance
- Base class for: `Music::Albums::List`, `Music::Songs::List`
- Uses STI via `type` column

## Associations
- `has_many :list_items` - Items contained in this list
- `belongs_to :submitted_by` (User, optional) - User who created the list
- `has_many :list_penalties` - Join table for penalties
- `has_many :penalties` - Applied penalties for ranking adjustments
- `has_many :ai_chats` - AI conversations related to this list

## Enums
- `status`: unapproved (0), approved (1), rejected (2), active (3)

## Validations
- `name`: Required
- `type`: Required (STI discriminator)
- `status`: Required
- `url`: Must be valid URI format (allows blank)
- `num_years_covered`: Must be positive integer (allows nil)
- `items_json_format`: Custom validation for JSON data

## Callbacks

### `before_validation :parse_items_json_if_string`
Automatically parses JSON strings into Hash/Array before validation runs.

**Purpose**: PostgreSQL JSONB columns accept strings, but we want to store parsed objects for consistency.

**Behavior**:
- Only runs if `items_json` is a non-blank String
- Attempts to parse the string as JSON
- On success: Replaces string with parsed Hash/Array
- On failure: Leaves as string, letting validation catch the error

**Example**:
```ruby
list.items_json = '{"albums": [{"rank": 1}]}'
list.valid?
# items_json is now: {"albums" => [{"rank" => 1}]}
```

### `before_save :auto_simplify_html`
Generates simplified HTML from raw HTML for easier parsing.

**Conditions**: Only runs when:
- `raw_html` is present
- Record is new OR `raw_html` has changed

## Scopes
- `approved`: Lists with approved status
- `high_quality`: Lists marked as high quality sources
- `by_year(year)`: Lists published in a specific year
- `yearly_awards`: Lists marked as yearly awards

## Public Methods

### `#has_penalties?`
Returns true if any penalties are applied to this list.

### `#global_penalties`
Returns penalties that apply globally (not user-specific).

### `#user_penalties`
Returns penalties that apply to specific users.

### `#parse_with_ai!`
Triggers AI parsing of the list using the ImportService.

### `.median_list_count(type: nil)`
Class method that calculates median number of items across lists.

**Parameters**:
- `type`: Optional type filter (e.g., "Music::Albums::List")

**Returns**: Median count (Float or Integer) or 0 if no lists

## Private Methods

### `#parse_items_json_if_string`
See Callbacks section above.

### `#items_json_format`
Custom validation that ensures `items_json` is valid JSON.

**Validation Logic**:
- Allows nil/blank values
- Allows Hash or Array (already parsed)
- For String values: Attempts to parse as JSON
- On parse failure: Adds error to prevent 500 errors

**Error Message**: "must be valid JSON: [parse error details]"

**Why This Matters**: Without this validation, malformed JSON strings would cause PostgreSQL JSONB column errors (500 status). This validation catches the error early and returns 422 Unprocessable Entity with a user-friendly error message.

**Example Valid Values**:
```ruby
# All of these pass validation:
list.items_json = nil
list.items_json = {"albums" => [{"rank" => 1}]}
list.items_json = [{"rank" => 1}]
list.items_json = '{"albums": [{"rank": 1}]}'  # Auto-parsed by callback
```

**Example Invalid Value**:
```ruby
list.items_json = '{"albums": [invalid'
list.valid?
# => false
list.errors[:items_json]
# => ["must be valid JSON: unexpected token at '{\"albums\": [invalid'"]
```

### `#should_simplify_html?`
Returns true if HTML simplification should run.

### `#auto_simplify_html`
Calls the HTML SimplifierService to generate simplified HTML.

## Related Files
- Controller: `app/controllers/admin/music/lists_controller.rb`
- Subclass: `app/models/music/albums/list.rb`
- Service: `app/services/lists/import_service.rb`
- Service: `app/services/html/simplifier_service.rb`

## Design Decisions

### Why Parse JSON Strings in Model Instead of Controller?
Following Rails conventions, data normalization and validation belong in the model layer. This ensures:
1. Consistency across all code paths (admin, API, console, etc.)
2. Single source of truth for validation logic
3. Validation is automatically tested with model specs
4. Controllers remain thin and focused on HTTP concerns

### Why Use Both Callback and Validation?
- **Callback** (`parse_items_json_if_string`): Normalizes valid JSON strings to objects
- **Validation** (`items_json_format`): Catches invalid JSON and provides user feedback

This two-step approach allows valid JSON strings to pass through automatically while catching errors gracefully.
