# Actions::Admin::Music::MergeArtist

## Summary
Admin action that merges a source artist into a target artist. Invoked from the artist show page via the Actions dropdown. Validates user input and delegates to `Music::Artist::Merger` for the actual merge operation.

## Location
`app/lib/actions/admin/music/merge_artist.rb`

## Parent Class
Extends `Actions::Admin::BaseAction`

## Class Methods

### `.name`
Returns: `"Merge Another Artist Into This One"`

### `.message`
Returns: Instructions for the user about entering the source artist ID.

### `.confirm_button_label`
Returns: `"Merge Artist"`

### `.visible?(context = {})`
Returns: `true` only when `context[:view] == :show`
- This action only appears on the artist show page, not index or bulk actions.

## Instance Methods

### `#call`
Executes the merge action.
- Returns: `ActionResult` with status, message, and optional data

## Required Fields
| Field | Type | Description |
|-------|------|-------------|
| `source_artist_id` | Integer | ID of the artist to merge (will be deleted) |
| `confirm_merge` | String/Boolean | Must be "1" or `true` to confirm |

## Validation Rules
1. **Single model only** - Returns error if more than one artist selected
2. **Source required** - Returns error if `source_artist_id` is blank
3. **Confirmation required** - Returns error if `confirm_merge` is not "1" or `true`
4. **Source exists** - Returns error if source artist not found
5. **No self-merge** - Returns error if source ID equals target ID

## Controller Integration
Invoked via `POST /admin/artists/:id/execute_action` with params:
```ruby
{
  action_name: "MergeArtist",
  source_artist_id: 123,
  confirm_merge: "1"
}
```

## UI Integration
The merge modal in `app/views/admin/music/artists/show.html.erb` includes:
- Autocomplete field for searching source artist (excludes current artist)
- Confirmation checkbox
- Warning about permanent deletion

## Success Response
```ruby
ActionResult.new(
  status: :success,
  message: "Successfully merged 'Source Name' (ID: 123) into 'Target Name'. The source artist has been deleted."
)
```

## Error Responses
| Condition | Message |
|-----------|---------|
| Multiple artists | "This action can only be performed on a single artist." |
| Missing source | "Please select an artist to merge." |
| Missing confirmation | "Please confirm you understand this action cannot be undone." |
| Source not found | "Artist with ID {id} not found." |
| Self-merge | "Cannot merge an artist with itself. Please select a different artist." |
| Merger failure | "Failed to merge artists: {error details}" |

## Usage Example
```ruby
result = Actions::Admin::Music::MergeArtist.call(
  user: current_user,
  models: [target_artist],
  fields: {
    source_artist_id: 123,
    confirm_merge: "1"
  }
)

if result.success?
  redirect_to admin_artist_path(target_artist), notice: result.message
else
  render :show, alert: result.message
end
```

## Related Classes
- `Music::Artist::Merger` - Service that performs the actual merge
- `Actions::Admin::Music::MergeSong` - Similar action for songs
- `Actions::Admin::Music::MergeAlbum` - Similar action for albums
- `Actions::Admin::BaseAction` - Parent class with shared functionality

## Security
- Requires admin authentication (enforced by controller)
- Action only visible on show view (not bulk operations)
- Confirmation checkbox required to prevent accidental merges
