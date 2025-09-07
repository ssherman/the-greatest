# Avo::Actions::Lists::ImportFromMusicbrainzSeries

## Summary
AVO admin action that allows bulk import of albums from MusicBrainz series into Music::Albums::List records. Validates selected lists and enqueues background jobs for processing.

## Usage
Available in AVO admin interface on Music::Albums::List resources. Can be applied to single lists or multiple selected lists.

## Validation
Before enqueuing jobs, the action validates that:
1. Selected lists are instances of `Music::Albums::List` (not other list types)
2. Selected lists have `musicbrainz_series_id` present
3. Logs warnings for invalid lists and excludes them from processing

## Process Flow
1. **Validation** - Filters query to only valid Music::Albums::List records with series IDs
2. **Job Enqueueing** - Creates separate background job for each valid list
3. **User Feedback** - Returns success message with count of enqueued jobs

## Parameters
- `query` - AVO query object containing selected list records
- `fields` - Form fields (unused)
- `current_user` - Current admin user (unused)
- `resource` - AVO resource context (unused)

## Return Values
- **Success** - `succeed "X list(s) queued for MusicBrainz series import..."`
- **Error** - `error "No valid lists found. Lists must be Music::Albums::List with a MusicBrainz series ID."`

## Background Processing
Each valid list triggers `ImportListFromMusicbrainzSeriesJob.perform_async(list.id)` which:
1. Finds the list by ID
2. Calls `DataImporters::Music::Lists::ImportFromMusicbrainzSeries.call(list: list)`
3. Imports albums and creates list items

## Error Handling
- Invalid list types are logged and skipped
- Lists without series IDs are logged and skipped
- Returns user-friendly error if no valid lists found
- Individual job failures handled by Sidekiq retry mechanism

## Configuration
```ruby
self.name = "Import from MusicBrainz Series"
self.message = "This will import albums from the MusicBrainz series associated with the selected list(s) in the background."
self.confirm_button_label = "Import from Series"
```

## Admin Interface Location
- Available on: `Avo::Resources::MusicAlbumsList`
- Appears as: Bulk action in list view and single action in show view
- Requires: Lists with `musicbrainz_series_id` populated

## Dependencies
- `Music::Albums::List` model
- `ImportListFromMusicbrainzSeriesJob` background job
- Sidekiq for job processing
- AVO framework for admin interface

## Usage Examples

### Single List Import
1. Navigate to Music Albums List in AVO admin
2. Open specific list record
3. Click "Import from MusicBrainz Series" action
4. Confirm import
5. Monitor job progress in Sidekiq dashboard

### Bulk Import
1. Navigate to Music Albums Lists index
2. Select multiple lists with series IDs
3. Choose "Import from MusicBrainz Series" from bulk actions
4. Confirm import
5. Monitor job progress for each list

## Related Classes
- `ImportListFromMusicbrainzSeriesJob` - Background job triggered by this action
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Core import logic
- `Music::Albums::List` - Target list model
- `Avo::Resources::MusicAlbumsList` - AVO resource that includes this action