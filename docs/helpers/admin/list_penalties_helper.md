# Admin::ListPenaltiesHelper

## Summary
Helper module providing utility methods for working with list penalties in the admin interface. Primary purpose is filtering available penalties based on list type and current attachments.

## Module Type
Controller helper module, included in admin controllers and available in admin views.

## Public Methods

### `#available_penalties(list)`
Returns a filtered collection of penalties that can be attached to the given list.

**Parameters**:
- `list` (List) - The list to filter penalties for

**Returns**:
- `ActiveRecord::Relation<Penalty>` - Ordered collection of available penalties

**Filtering Logic**:
1. **Static Only**: Uses `Penalty.static` scope to exclude dynamic penalties
   - Dynamic penalties are auto-applied during weight calculation
   - Manual attachment only allowed for static penalties
2. **Media Compatibility**: Matches penalties to list media type
   - Extracts media type via `list.type.split("::").first` (e.g., "Music", "Books")
   - Includes `Global::Penalty` (works with all list types)
   - Includes media-specific penalties (e.g., `Music::Penalty` for Music lists)
3. **Already Attached**: Excludes penalties already in `list.penalties`
   - Uses `where.not(id: list.penalties.pluck(:id))`
4. **Alphabetical Order**: Orders by penalty name for consistent UI

**Example**:
```ruby
# For a Music::Songs::TopList
available_penalties(@list)
# Returns: Global::Penalty instances + Music::Penalty instances
#          (excluding any already attached to @list)
#          (excluding any dynamic penalties)
#          (ordered by name)
```

**SQL Generated**:
```sql
SELECT penalties.*
FROM penalties
WHERE penalties.dynamic_type IS NULL
  AND penalties.type IN ('Global::Penalty', 'Music::Penalty')
  AND penalties.id NOT IN (1, 2, 3) -- already attached IDs
ORDER BY penalties.name
```

## Usage Context

### In ViewComponents
Used by `Admin::AttachPenaltyModalComponent` to populate the penalty dropdown:
```erb
<%= f.select :penalty_id,
    options_from_collection_for_select(
      helpers.available_penalties(@list), :id, :name
    ) %>
```

### In Controllers
Available in admin controllers but typically accessed via helpers proxy in views/components.

## Cross-Domain Design
The helper is domain-agnostic:
- Dynamically extracts media type from list STI class
- Works with any List subclass (Music, Books, Movies, Games)
- No hardcoded media type logic
- Relies on Penalty STI hierarchy for type filtering

## Dependencies
- `Penalty` model with `.static` scope
- `List` model with polymorphic STI structure
- `ListPenalty` join table for existing associations

## Related Components
- `Admin::AttachPenaltyModalComponent` - Primary consumer of this helper
- `Admin::ListPenaltiesController` - Uses implicitly via component rendering
- `ListPenalty` model - Validates compatibility after selection
- `Penalty` model - Provides static scope and STI types
