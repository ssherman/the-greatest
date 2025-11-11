# Actions::Admin::Music::MergeSong

## Summary
Admin action for merging duplicate songs. Consolidates all associations from a source song into a target song, then deletes the source song. Single-record action only (appears on song show page).

**Location**: `app/lib/actions/admin/music/merge_song.rb`

## Inheritance
Inherits from `Actions::Admin::BaseAction` which provides:
- Result pattern (`succeed` and `error` methods)
- User context (`current_user`)
- Model context (`models` array)
- Field context (`fields` hash)

## Class Methods

### `.name`
Returns: `"Merge Another Song Into This One"`
- Displayed as action name in UI

### `.message`
Returns descriptive message for users:
```
Enter the ID of a duplicate song to merge into the current song.
The source song will be permanently deleted after merging.
```

### `.confirm_button_label`
Returns: `"Merge Song"`
- Used as submit button text in modal form

### `.visible?(context = {})`
Returns: `true` if `context[:view] == :show`
- Action only appears on song show page, not on index

## Instance Method

### `#call`
Performs song merge operation.

**Preconditions**:
- Exactly 1 song selected (target)
- `source_song_id` field provided
- `confirm_merge` field checked
- Source song exists in database
- Source song ≠ target song

**Fields**:
- `source_song_id` (integer or string, required) - ID of duplicate song to delete
- `confirm_merge` (boolean or string "1", required) - User confirmation

**Process**:
1. Validates single-record selection
2. Extracts and validates fields from form submission
3. Loads source song by ID
4. Validates source ≠ target
5. Delegates to `Music::Song::Merger.call(source:, target:)`
6. Returns success or error result

**Postconditions** (on success):
- Source song deleted
- All source associations transferred to target:
  - `tracks` (via song_id)
  - `identifiers` (merged, duplicates skipped)
  - `category_items` (merged, duplicates skipped)
  - `external_links` (merged, duplicates skipped)
  - `list_items` (updated to point to target)
  - `ranked_items` (updated to point to target)
- **Note**: `song_artists` NOT transferred (tracks association handles artist linkage)
- Search indexes updated
- Ranking recalculation scheduled

**Returns**: ActionResult with success/error status and message

## Error Messages

| Condition | Message |
|-----------|---------|
| Multiple songs selected | "This action can only be performed on a single song." |
| Missing source_song_id | "Please enter the ID of the song to merge." |
| Missing confirmation | "Please confirm you understand this action cannot be undone." |
| Source song not found | "Song with ID {id} not found." |
| Self-merge attempt | "Cannot merge a song with itself. Please enter a different song ID." |
| Merger service failure | "Failed to merge songs: {errors}" |

## Success Message
```
Successfully merged '{source_title}' (ID: {source_id}) into '{target_title}'.
The source song has been deleted.
```

## UI Integration

### Modal Form
**Location**: `app/views/admin/music/songs/show.html.erb`
**Trigger**: "Merge Another Song" in Actions dropdown
**Controller**: `modal-form` Stimulus controller (auto-closes on success)
**Submission**: `POST /admin/songs/:id/execute_action` with `action_name=MergeSong`

### Form Fields
```erb
<%= f.hidden_field :action_name, value: "MergeSong" %>
<%= f.number_field :source_song_id, required: true %>
<%= f.check_box :confirm_merge, required: true %>
```

## Dependencies
- **Service**: `Music::Song::Merger` - Core merge logic (transactional, ranking-aware)
- **Model**: `Music::Song` - Source and target songs
- **Background Jobs**:
  - Search reindexing (via `SearchIndexable` concern)
  - Ranking recalculation (via `Music::Song::Merger`)

## Business Rules

### Association Transfer Strategy
- **Tracks**: Transferred (contains artist info via release)
- **Identifiers**: Merged (e.g., combine MusicBrainz IDs)
- **Categories**: Merged (union of genre tags)
- **External Links**: Merged (e.g., combine Spotify, Apple Music links)
- **List Items**: Updated (maintains user list memberships)
- **Ranked Items**: Updated (preserves ranking positions)
- **Song Artists**: NOT transferred (track association suffices)

### Transaction Safety
Merge wrapped in database transaction via `Music::Song::Merger`:
- All-or-nothing operation
- Rollback on any error
- Foreign key constraints enforced

### Search Consistency
- Source song removed from OpenSearch index (via `after_destroy` callback)
- Target song reindexed with merged data

### Ranking Impact
- Schedules background recalculation for affected ranking configurations
- Does not block merge operation

## Testing
**Test Location**: `test/lib/actions/admin/music/merge_song_test.rb`
**Test Coverage**: 6 tests
- Success case with all associations
- Missing source_song_id validation
- Missing confirmation validation
- Source song not found error
- Self-merge prevention
- Multiple selection error

**Fixtures Required**:
- Two songs (source and target)
- Associated records (tracks, categories, identifiers, list_items)

## Performance Considerations
- **Database**: Single transaction, moderately expensive due to cascading updates
- **Search**: Async reindexing, does not block response
- **Typical Duration**: 100-500ms depending on association count
- **Ranking Recalc**: Queued for background processing

## Related Documentation
- **Merger Service**: `docs/lib/music/song/merger.md`
- **Model**: `docs/models/music/song.md`
- **Controller**: `docs/controllers/admin/music/songs_controller.md`
- **Base Action**: `docs/lib/actions/admin/base_action.md`
- **Implementation Task**: `docs/todos/completed/075-custom-admin-phase-4-songs.md`

## Common Use Cases
1. **Duplicate song cleanup**: Merge misspelled or duplicate entries
2. **Data consolidation**: Combine separately-imported versions of same song
3. **List cleanup**: Fix songs that appear multiple times in rankings/lists

## Warnings
- **Irreversible**: Source song permanently deleted, cannot be undone
- **Association loss**: Song artist associations NOT transferred (by design)
- **ID changes**: Source song ID no longer valid after merge
- **External references**: Any external systems referencing source song ID will break
