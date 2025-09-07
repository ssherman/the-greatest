# MusicBrainz Series Import Feature

## Summary
Complete feature implementation for importing album rankings from MusicBrainz series data into Music::Albums::List records. Enables automated population of curated "greatest" album lists from authoritative MusicBrainz series.

## Feature Overview
This feature allows administrators to:
1. Associate Music::Albums::List records with MusicBrainz Series IDs
2. Trigger automatic import of all albums from the series
3. Create properly positioned list items with full album metadata
4. Process imports in the background for performance

## Implementation Components

### Database Changes
- **Migration**: `add_musicbrainz_series_id_to_lists.rb`
  - Added `musicbrainz_series_id` string field to `lists` table
  - Field is used only by Music::Albums::List STI subclass

### Models
- **List** (`app/models/list.rb`)
  - Added `musicbrainz_series_id` field to database schema
  - Updated documentation to reflect new field

- **Music::Album** (`app/models/music/album.rb`)
  - Added `with_identifier(type, value)` scope for identifier lookups
  - Added `with_musicbrainz_release_group_id(mbid)` convenience scope
  - Supports deduplication during import operations

### Service Objects
- **ImportFromMusicbrainzSeries** (`app/lib/data_importers/music/lists/import_from_musicbrainz_series.rb`)
  - Core import service with comprehensive error handling
  - Validates list type and series ID presence
  - Fetches series data from MusicBrainz API
  - Imports individual albums using existing Album::Importer
  - Creates positioned list items while avoiding duplicates
  - Returns detailed success/failure reporting

### Background Jobs
- **ImportListFromMusicbrainzSeriesJob** (`app/sidekiq/import_list_from_musicbrainz_series_job.rb`)
  - Sidekiq job for asynchronous processing
  - Finds list by ID and delegates to import service
  - Uses default queue for processing

### Admin Interface (AVO)
- **MusicAlbumsList Resource** (`app/avo/resources/music_albums_list.rb`)
  - Added `musicbrainz_series_id` field display/editing
  - Custom list_items display with position and title
  - Includes import action

- **Import Action** (`app/avo/actions/lists/import_from_musicbrainz_series.rb`)
  - Bulk action for triggering series imports
  - Validates selected lists (type and series ID)
  - Enqueues background jobs for each valid list
  - Provides user feedback and error messages

### Testing
- **Service Tests** (`test/lib/data_importers/music/lists/import_from_musicbrainz_series_test.rb`)
  - Comprehensive test coverage with mocha mocking
  - Tests success scenarios, failures, validation, and edge cases
  - 7 tests with 35 assertions covering all functionality

- **Job Tests** (`test/sidekiq/import_list_from_musicbrainz_series_job_test.rb`)
  - Basic job functionality testing
  - Verifies service delegation and parameter passing

## Usage Workflow

### Admin Setup
1. Navigate to Music Albums List in AVO admin
2. Create or edit a list record
3. Set the `musicbrainz_series_id` field to the MusicBrainz Series UUID
4. Save the list

### Import Process
1. Select list(s) in AVO admin interface
2. Choose "Import from MusicBrainz Series" action
3. Confirm the import operation
4. Background jobs process each list asynchronously
5. Monitor progress in Sidekiq dashboard
6. Imported albums appear as positioned list items

### Import Results
- Albums are imported with full metadata (title, artists, release year)
- External identifiers and categories are populated
- List items maintain series-defined positioning
- Duplicate albums are automatically skipped
- Detailed logging for troubleshooting

## Technical Architecture

### Data Flow
1. **Trigger**: Admin action in AVO interface
2. **Validation**: Action validates lists and enqueues jobs
3. **Background Processing**: Sidekiq job processes each list
4. **Series Retrieval**: Service fetches MusicBrainz series data
5. **Album Import**: Individual albums imported via existing importers
6. **List Population**: Positioned list items created
7. **Completion**: Success/failure results logged and returned

### Error Handling
- Graceful handling of API failures
- Validation of list types and series IDs
- Logging of import failures and warnings
- Continuation of processing when individual albums fail
- User-friendly error messages in admin interface

### Dependencies
- **External APIs**: MusicBrainz for series and album data
- **Background Processing**: Sidekiq for job queuing
- **Existing Services**: Album/Artist import infrastructure
- **Admin Framework**: AVO for user interface

## Performance Considerations
- Background processing prevents UI blocking
- Existing album detection avoids duplicate imports
- Rate limiting respects external API constraints
- Batch processing for multiple lists
- Comprehensive logging for monitoring

## Future Enhancements
- Progress tracking for long-running imports
- Retry mechanisms for failed album imports
- Bulk series management interface
- Import scheduling and automation
- Series metadata caching

## Related Documentation
- `/docs/models/list.md` - Base List model documentation
- `/docs/models/music/albums_list.md` - Music::Albums::List specific docs
- `/docs/models/music/album.md` - Album model with new scopes
- `/docs/services/data_importers/music/lists/import_from_musicbrainz_series.md` - Core service
- `/docs/sidekiq/import_list_from_musicbrainz_series_job.md` - Background job
- `/docs/admin/actions/import_from_musicbrainz_series.md` - AVO action