# Avo::Actions::Lists::Music::Songs::EnrichItemsJson

## Summary
Avo bulk action that enriches `items_json` on selected `Music::Songs::List` records with MusicBrainz metadata. Provides admin UI for triggering enrichment jobs.

## Purpose
Allows admins to select one or more song lists in the Avo interface and queue background jobs to enrich their items_json with MusicBrainz recording data. Validates lists before queuing to ensure they have the necessary data.

## Configuration

### Name
```ruby
self.name = "Enrich items_json with MusicBrainz data"
```
Display name shown in Avo bulk actions dropdown.

### Message
```ruby
self.message = "This will enrich the items_json field with MusicBrainz metadata for the selected list(s) in the background."
```
Confirmation message shown to user before action executes.

### Confirm Button
```ruby
self.confirm_button_label = "Enrich items json"
```
Label for the confirmation button in the modal.

## Public Methods

### `#handle(query:, fields:, current_user:, resource:, **args)`
Executes the action on selected records.

**Parameters:**
- `query` (ActiveRecord::Relation) - Selected list records
- `fields` (Hash) - Form field values (unused in this action)
- `current_user` (User) - Current admin user
- `resource` (Avo::Resource) - The Avo resource instance
- `**args` - Additional arguments

**Returns:**
- Avo action result (success or error)

**Processing Flow:**
1. Load all record IDs (triggers query)
2. Filter for valid lists:
   - Must be `Music::Songs::List` type
   - Must have items_json populated
   - Must have "songs" array in items_json
3. Log warnings for invalid lists
4. Return error if no valid lists
5. Queue job for each valid list
6. Return success message with count

**Example Behavior:**
```ruby
# User selects 5 lists:
# - 3 are Music::Songs::List with items_json
# - 1 is Music::Songs::List without items_json
# - 1 is Music::Albums::List

# Result: 3 jobs queued, 2 skipped with warnings
# Message: "3 list(s) queued for items_json enrichment..."
```

## Validation Logic

### Type Validation
```ruby
is_song_list = list.is_a?(::Music::Songs::List)

unless is_song_list
  Rails.logger.warn "Skipping non-song list: #{list.name} (ID: #{list.id}, Type: #{list.class})"
end
```
Ensures only song lists are processed. Logs warning and skips other types.

### Data Validation
```ruby
has_items_json = list.items_json.present? && list.items_json["songs"].is_a?(Array)

unless has_items_json
  Rails.logger.warn "Skipping list without items_json: #{list.name} (ID: #{list.id})"
end
```
Ensures list has items_json with songs array. Logs warning and skips invalid data.

### Combined Validation
```ruby
valid_lists = query.select do |list|
  is_song_list = list.is_a?(::Music::Songs::List)
  has_items_json = list.items_json.present? && list.items_json["songs"].is_a?(Array)

  is_song_list && has_items_json
end
```
Only lists passing both validations are queued for processing.

## Error Handling

### No Valid Lists
```ruby
if valid_lists.empty?
  return error "No valid lists found. Lists must be Music::Songs::List with populated items_json."
end
```
Returns error message to user if no lists can be processed.

### Job Queueing
```ruby
valid_lists.each do |list|
  Music::Songs::EnrichListItemsJsonJob.perform_async(list.id)
end
```
Jobs are queued individually. If one fails to queue, others still process.

## User Feedback

### Success Message
```ruby
succeed "#{valid_lists.length} list(s) queued for items_json enrichment. Each list will be processed in a separate background job."
```
Tells user how many jobs were queued and that processing is async.

### Warning Logs
Skipped lists are logged but not shown to user:
```ruby
Rails.logger.warn "Skipping non-song list: Best Albums (ID: 123, Type: Music::Albums::List)"
Rails.logger.warn "Skipping list without items_json: Empty List (ID: 456)"
```

## Dependencies

### Models
- `Music::Songs::List` - Lists being validated and processed

### Jobs
- `Music::Songs::EnrichListItemsJsonJob` - Background job for enrichment

### Framework
- `Avo::BaseAction` - Base class for Avo actions
- `Rails.logger` - Logging

## Resource Integration

### Registration
Action must be registered in the resource file:

```ruby
# app/avo/resources/music_songs_list.rb
class Avo::Resources::MusicSongsList < Avo::Resources::List
  def actions
    super
    action Avo::Actions::Lists::Music::Songs::EnrichItemsJson
  end
end
```

### Visibility
- Shows in bulk actions dropdown when one or more lists are selected
- Available in index view
- Also appears in single-record show view

## Usage Patterns

### From Avo UI
1. Navigate to Music::Songs::List index page
2. Select one or more lists using checkboxes
3. Click "Actions" dropdown
4. Select "Enrich items_json with MusicBrainz data"
5. Review confirmation message
6. Click "Enrich items json" button
7. See success/error message
8. Jobs process in background

### Result Messages

**Success:**
```
3 list(s) queued for items_json enrichment. Each list will be processed in a separate background job.
```

**Error (no valid lists):**
```
No valid lists found. Lists must be Music::Songs::List with populated items_json.
```

## Validation Examples

### Valid List
```ruby
# ✅ Will be queued
{
  type: "Music::Songs::List",
  items_json: {
    "songs" => [
      {"rank" => 1, "title" => "Come Together", "artists" => ["The Beatles"]}
    ]
  }
}
```

### Invalid Lists
```ruby
# ❌ Wrong type (skipped)
{
  type: "Music::Albums::List",
  items_json: {"albums" => [...]}
}

# ❌ No items_json (skipped)
{
  type: "Music::Songs::List",
  items_json: nil
}

# ❌ Empty items_json (skipped)
{
  type: "Music::Songs::List",
  items_json: {}
}

# ❌ Wrong structure (skipped)
{
  type: "Music::Songs::List",
  items_json: {"albums" => [...]}  # Should be "songs"
}
```

## Testing

Comprehensive test coverage would include:
- Action execution with valid lists
- Type validation (skips non-song lists)
- Data validation (skips lists without items_json)
- Mixed selection (some valid, some invalid)
- All invalid selections (error message)
- Job queueing verification

Note: Direct action testing can be complex due to Avo framework. Most testing is done via integration tests or console verification.

## Related Classes
- `Services::Lists::Music::Songs::ItemsJsonEnricher` - Core enrichment service
- `Music::Songs::EnrichListItemsJsonJob` - Job this action queues
- `Avo::Actions::Lists::Music::Albums::EnrichItemsJson` - Album version of this action
- `Avo::Resources::MusicSongsList` - Resource where action is registered

## Performance Considerations

### Query Loading
```ruby
query.pluck(:id)
```
Forces query execution to load IDs. Not strictly necessary but ensures records are loaded.

### Validation Performance
Validates each record individually. For 100+ selected records, validation may take a few seconds.

### Job Queueing
Jobs are queued synchronously in the action. For many lists, consider batching or async queueing.

## Common Issues

### Action Not Appearing
- Check action is registered in resource `actions` method
- Verify Avo is configured correctly
- Restart server after adding action

### Jobs Not Running
- Verify Sidekiq is running
- Check job queue in Sidekiq web UI
- Review logs for queueing errors

### All Lists Skipped
- Check lists have items_json populated
- Verify items_json has "songs" array (not "albums" or other keys)
- Review warning logs for specific skip reasons
