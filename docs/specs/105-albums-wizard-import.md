# 105 - Albums Wizard Import & Complete Steps

## Status
- **Status**: Not Started
- **Priority**: High
- **Created**: 2025-12-27
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Implement the import and complete steps for the Albums List Wizard. The import step creates album records from MusicBrainz data and links them to ListItems. The complete step shows a summary of the import.

**Goal**: Import albums from MusicBrainz and finalize the wizard.
**Scope**: Import step component, import job, complete step component.
**Non-goals**: Custom HTML import (albums without MB data stay unlinked).

## Context & Links
- Prerequisite: spec 100, 101, 102, 103, 104
- Songs import job: `app/sidekiq/music/songs/wizard_import_songs_job.rb`
- Album importer (exists): `app/lib/data_importers/music/album/importer.rb`
- MusicBrainz album provider (exists): `app/lib/data_importers/music/album/providers/music_brainz.rb`

## Interfaces & Contracts

### Background Job: Music::Albums::WizardImportAlbumsJob

```ruby
# app/sidekiq/music/albums/wizard_import_albums_job.rb
class Music::Albums::WizardImportAlbumsJob
  include Sidekiq::Job

  def perform(list_id)
    @list = Music::Albums::List.find(list_id)

    case import_source
    when "musicbrainz_series"
      import_from_musicbrainz_series
    when "custom_html"
      import_from_parsed_items
    end
  end

  private

  def import_from_musicbrainz_series
    # Use existing series importer if available
    # Import albums from MusicBrainz series
    # Create ListItems for each album
  end

  def import_from_parsed_items
    # For each item with mb_release_group_id but no listable_id:
    # 1. Call DataImporters::Music::Album::Importer with MB ID
    # 2. Link imported album to ListItem
    # 3. Mark as verified
  end
end
```

### Step Component: ImportStepComponent

```ruby
# app/components/admin/music/albums/wizard/import_step_component.rb
class Admin::Music::Albums::Wizard::ImportStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  # Shows items to be imported (those with mb_release_group_id but no listable_id)
  # Shows items already linked (those with listable_id)
  # Shows items that cannot be imported (no MB data)

  def items_to_import
    @list.list_items.unverified.select { |i| i.metadata["mb_release_group_id"].present? && i.listable_id.nil? }
  end

  def items_already_linked
    @list.list_items.where.not(listable_id: nil)
  end

  def items_without_data
    @list.list_items.where(listable_id: nil).reject { |i| i.metadata["mb_release_group_id"].present? }
  end

  # Job metadata: imported_count, failed_count, skipped_count
end
```

### Step Component: CompleteStepComponent

```ruby
# app/components/admin/music/albums/wizard/complete_step_component.rb
class Admin::Music::Albums::Wizard::CompleteStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  def total_items
    @list.list_items.count
  end

  def linked_items
    @list.list_items.where.not(listable_id: nil).count
  end

  def verified_items
    @list.list_items.verified.count
  end
end
```

### Import Job Metadata Schema

```json
{
  "status": "completed",
  "progress": 100,
  "metadata": {
    "imported_count": 45,
    "failed_count": 2,
    "skipped_count": 3,
    "errors": [
      { "item_id": 123, "error": "MusicBrainz API timeout" }
    ]
  }
}
```

### ListItem Metadata (after import)

```json
{
  "title": "The Dark Side of the Moon",
  "artists": ["Pink Floyd"],
  "mb_release_group_id": "abc123...",
  "imported_at": "2025-12-27T15:30:00Z",
  "imported_album_id": 456
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Review step completed
- At least one item has valid match (verified or has MB data)

**Postconditions:**
- Albums imported from MusicBrainz data
- ListItems linked to imported albums
- Items marked as verified
- Wizard state completed_at timestamp set

**Edge cases:**
- Import failure for single item: continue with others, log error
- Album already exists: link to existing, don't re-import
- MusicBrainz rate limiting: job should handle gracefully with retries
- Series import: imports all albums in series

### Non-Functionals
- Import job < 10 minutes for 100 items (MusicBrainz rate limiting is main constraint)
- Progress updates after each item
- Idempotent: re-running skips already imported items

## Acceptance Criteria
- [ ] Import step shows breakdown of items (to import, already linked, no data)
- [ ] Clicking "Import" triggers WizardImportAlbumsJob
- [ ] Job imports albums using existing Album::Importer
- [ ] Job links imported albums to ListItems
- [ ] Job marks items as verified after successful import
- [ ] Progress bar shows import progress
- [ ] Failed imports logged with error details
- [ ] Complete step shows summary statistics
- [ ] Complete step has link to view the list
- [ ] Wizard state marked as completed

### Golden Examples

**Import from MB data:**
```ruby
# For each item with mb_release_group_id
result = DataImporters::Music::Album::Importer.call(
  query: { musicbrainz_release_group_id: item.metadata["mb_release_group_id"] }
)

if result.success?
  item.update!(
    listable: result.item,
    verified: true,
    metadata: item.metadata.merge(
      "imported_at" => Time.current.iso8601,
      "imported_album_id" => result.item.id
    )
  )
end
```

---

## Agent Hand-Off

### Constraints
- Reuse existing DataImporters::Music::Album::Importer
- Follow songs import job pattern
- Handle MusicBrainz rate limiting (1 req/sec)

### Required Outputs
- `app/sidekiq/music/albums/wizard_import_albums_job.rb`
- `app/components/admin/music/albums/wizard/import_step_component.rb`
- `app/components/admin/music/albums/wizard/import_step_component.html.erb`
- `app/components/admin/music/albums/wizard/complete_step_component.rb`
- `app/components/admin/music/albums/wizard/complete_step_component.html.erb`
- Test files for job and components

### Sub-Agent Plan
1) codebase-analyzer → Review songs import job implementation
2) codebase-analyzer → Verify Album::Importer API and usage

### Test Seed / Fixtures
- ListItems with mb_release_group_id in metadata
- ListItems already linked to albums

---

## Implementation Notes (living)
- Approach taken:
- Important decisions:

### Key Files Touched (paths only)
- `app/sidekiq/music/albums/wizard_import_albums_job.rb`
- `app/components/admin/music/albums/wizard/import_step_component.rb`
- `app/components/admin/music/albums/wizard/complete_step_component.rb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`

### Challenges & Resolutions
-

### Deviations From Plan
-

## Acceptance Results
- Date, verifier, artifacts:

## Future Improvements
- Parallel import with rate limiting
- Retry failed imports button

## Related PRs
-

## Documentation Updated
- [ ] Class docs for new files
