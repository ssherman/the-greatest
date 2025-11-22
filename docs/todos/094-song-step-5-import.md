# [094] - Song Wizard: Step 5 - Import & Complete

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 9 of 10

## Overview
Import missing songs from MusicBrainz (or series if that path chosen), link to list_items, mark as verified. Final step before completion.

## Acceptance Criteria
- [ ] Shows list of items queued for import (has mb_recording_id but no song_id)
- [ ] Checkboxes to select which to import
- [ ] "Import Selected" button enqueues jobs
- [ ] Progress shows import status
- [ ] After import completes, auto-links to list_items
- [ ] If MusicBrainz series path: shows series import instead
- [ ] "Complete List" button finalizes wizard

## Key Components

### View (Custom HTML Path)
**File**: `app/views/admin/music/songs/list_wizard/steps/_import.html.erb`
- List of items to import (title, artists, mb_recording_id)
- Checkboxes for selection
- Import button
- Progress for each import

### View (MusicBrainz Series Path)
**File**: `app/views/admin/music/songs/list_wizard/steps/_import_series.html.erb`
- MusicBrainz series ID input
- "Import from Series" button
- Progress bar

### Job (Custom HTML)
**File**: `app/sidekiq/music/songs/wizard_import_song_job.rb`
```ruby
def perform(list_item_id)
  item = ListItem.find(list_item_id)
  mb_recording_id = item.metadata["mb_recording_id"]

  # Import song from MusicBrainz
  result = DataImporters::Music::Song::Importer.call(
    musicbrainz_recording_id: mb_recording_id
  )

  if result.success?
    song = result.item
    # Link to list_item and mark verified
    item.update!(listable: song, verified: true)
  else
    # Update metadata with error
    item.update!(metadata: item.metadata.merge("import_error" => result.error))
  end
end
```

### Job (MusicBrainz Series)
**File**: `app/sidekiq/music/songs/import_from_musicbrainz_series_job.rb`
Reuse existing series importer (see albums implementation)

**Reference**: `docs/admin/actions/import_from_musicbrainz_series.md`

## Tests
- [ ] Import job creates songs
- [ ] Links created songs to list_items
- [ ] Marks items as verified
- [ ] Series import works (if that path chosen)
- [ ] Error handling works
- [ ] Complete button marks wizard finished

## Related
- **Previous**: [093] Step 4: Actions
- **Next**: [095] Polish & Integration
- **Reference**: `app/lib/data_importers/music/song/importer.rb`
