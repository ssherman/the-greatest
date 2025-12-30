# 102 - Albums Wizard Enrich Step

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-12-27
- **Started**: 2025-12-28
- **Completed**: 2025-12-28
- **Developer**: Claude Code

## Overview
Implement the enrich step for the Albums List Wizard. This step takes parsed ListItems and enriches them with data from OpenSearch (local albums) and MusicBrainz (release groups), linking items to existing albums where matches are found.

**Goal**: Match parsed album data to existing albums or MusicBrainz release groups.
**Scope**: Enrich step component, background job, ListItemEnricher service.
**Non-goals**: AI validation of matches (handled in spec 103).

## Context & Links
- Prerequisite: spec 100, 101
- Songs enricher reference: `app/lib/services/lists/music/songs/list_item_enricher.rb`
- ReleaseGroupSearch (exists): `app/lib/music/musicbrainz/search/release_group_search.rb`
- AlbumAutocomplete (exists): `app/lib/search/music/search/album_autocomplete.rb`

## Interfaces & Contracts

### Background Job: Music::Albums::WizardEnrichListItemsJob

```ruby
# app/sidekiq/music/albums/wizard_enrich_list_items_job.rb
class Music::Albums::WizardEnrichListItemsJob
  include Sidekiq::Job

  PROGRESS_UPDATE_INTERVAL = 10

  def perform(list_id)
    # 1. Load list and unverified items
    # 2. Update step status to "running"
    # 3. Clear previous enrichment data if re-enriching
    # 4. For each item, call ListItemEnricher
    # 5. Track stats: opensearch_matches, musicbrainz_matches, not_found
    # 6. Update progress periodically
    # 7. Update step status to "completed" with stats
  end
end
```

### Service: Services::Lists::Music::Albums::ListItemEnricher

```ruby
# app/lib/services/lists/music/albums/list_item_enricher.rb
module Services::Lists::Music::Albums
  class ListItemEnricher
    def initialize(list_item)
      @list_item = list_item
    end

    def call
      # 1. Try OpenSearch first (local albums)
      # 2. If no match, try MusicBrainz ReleaseGroupSearch
      # 3. Return result with match source
    end

    private

    def find_via_opensearch(title, artists)
      # Use Search::Music::Search::AlbumByTitleAndArtists
    end

    def find_via_musicbrainz(title, artists)
      # Use Music::Musicbrainz::Search::ReleaseGroupSearch
    end
  end
end
```

### New Search Service: Search::Music::Search::AlbumByTitleAndArtists

Similar to `SongByTitleAndArtists`, searches local albums index:

```ruby
# app/lib/search/music/search/album_by_title_and_artists.rb
module Search::Music::Search
  class AlbumByTitleAndArtists < BaseSearch
    def initialize(title:, artists:, size: 1, min_score: 5.0)
      # Build OpenSearch query for albums
    end
  end
end
```

### Step Component: EnrichStepComponent

```ruby
# app/components/admin/music/albums/wizard/enrich_step_component.rb
class Admin::Music::Albums::Wizard::EnrichStepComponent < ViewComponent::Base
  def initialize(list:)
    @list = list
  end

  # Expose job metadata: opensearch_matches, musicbrainz_matches, not_found_count
  # Status helpers: idle_or_failed?, running?, completed?, failed?
end
```

### ListItem Metadata Schema (after enrichment)

**OpenSearch match:**
```json
{
  "title": "The Dark Side of the Moon",
  "artists": ["Pink Floyd"],
  "release_year": 1973,
  "album_id": 123,
  "album_name": "The Dark Side of the Moon",
  "opensearch_match": true,
  "opensearch_score": 15.7
}
```

**MusicBrainz match:**
```json
{
  "title": "The Dark Side of the Moon",
  "artists": ["Pink Floyd"],
  "release_year": 1973,
  "mb_release_group_id": "a1b2c3d4-...",
  "mb_release_group_name": "The Dark Side of the Moon",
  "mb_artist_ids": ["f1e2d3c4-..."],
  "mb_artist_names": ["Pink Floyd"],
  "musicbrainz_match": true
}
```

### Behaviors (pre/postconditions)

**Preconditions:**
- Parse step completed with ListItems created
- ListItems have `metadata` with `title` and `artists`

**Postconditions:**
- Items with OpenSearch match have `listable_id` set to `Music::Album.id`
- Items with MusicBrainz match have `mb_release_group_id` in metadata (no `listable_id` yet)
- Items without match have neither (will show in review as "missing")
- Step metadata includes match counts

**Edge cases:**
- Multiple artists: search with first artist, fallback to combined string
- Year mismatch: still match if title/artist match closely
- Re-enriching: clears previous enrichment data before re-running

### Non-Functionals
- Enrich job should complete in < 5 minutes for 100 items
- Progress updates every 10 items
- MusicBrainz rate limiting: 1 request per second (handled by client)

## Acceptance Criteria
- [x] Enrich step component shows job progress
- [x] Job enriches all unverified items
- [x] OpenSearch matches link directly to existing albums
- [x] MusicBrainz matches store release group ID in metadata
- [x] Stats show match breakdown (OpenSearch vs MusicBrainz vs not found)
- [x] "Re-enrich" button clears and re-runs enrichment
- [x] Progress bar updates during job execution

### Golden Examples

**OpenSearch match result:**
```ruby
list_item.update!(
  listable: existing_album,  # Music::Album record
  metadata: original_metadata.merge(
    "album_id" => existing_album.id,
    "album_name" => existing_album.title,
    "opensearch_match" => true,
    "opensearch_score" => 15.7
  )
)
```

---

## Agent Hand-Off

### Constraints
- Follow songs ListItemEnricher pattern
- Reuse existing ReleaseGroupSearch (search_by_artist_and_title)
- Create AlbumByTitleAndArtists following SongByTitleAndArtists pattern

### Required Outputs
- `app/sidekiq/music/albums/wizard_enrich_list_items_job.rb`
- `app/lib/services/lists/music/albums/list_item_enricher.rb`
- `app/lib/search/music/search/album_by_title_and_artists.rb`
- `app/components/admin/music/albums/wizard/enrich_step_component.rb`
- `app/components/admin/music/albums/wizard/enrich_step_component.html.erb`
- Test files for all new classes

### Sub-Agent Plan
1) codebase-analyzer → Review songs ListItemEnricher implementation
2) codebase-pattern-finder → Find SongByTitleAndArtists pattern for albums version

### Test Seed / Fixtures
- ListItems with metadata from parse step
- Existing Music::Album records for OpenSearch matching

---

## Implementation Notes (living)
- Approach taken: Followed the songs wizard enricher pattern closely, adapting for albums
- Important decisions: Used ReleaseGroupSearch for MusicBrainz lookups (release groups = albums)

### Key Files Touched (paths only)
- `app/sidekiq/music/albums/wizard_enrich_list_items_job.rb`
- `app/lib/services/lists/music/albums/list_item_enricher.rb`
- `app/lib/search/music/search/album_by_title_and_artists.rb`
- `app/components/admin/music/albums/wizard/enrich_step_component.rb`
- `app/components/admin/music/albums/wizard/enrich_step_component.html.erb`
- `app/helpers/admin/music/albums/list_wizard_helper.rb`
- `test/sidekiq/music/albums/wizard_enrich_list_items_job_test.rb`
- `test/lib/services/lists/music/albums/list_item_enricher_test.rb`
- `test/lib/search/music/search/album_by_title_and_artists_test.rb`
- `test/components/admin/music/albums/wizard/enrich_step_component_test.rb`
- `test/lib/services/lists/wizard/state_manager_test.rb` (updated test expectation)

### Challenges & Resolutions
- Mocha stub behavior for class methods was inconsistent in tests; resolved by adding defensive stubs for MusicBrainz in OpenSearch tests
- StateManager test expected base class for albums; updated to expect Music::Albums::StateManager

### Deviations From Plan
- None significant; implementation followed the songs pattern as specified

## Acceptance Results
- Date: 2025-12-28
- Verifier: Claude Code
- Test Results: 47 tests, 92 assertions, 0 failures, 0 errors
- All acceptance criteria verified through passing tests

## Future Improvements
- Consider extracting base ListItemEnricher between songs and albums
- Could add additional data providers (Discogs, AllMusic)

## Related PRs
- (To be added when PR is created)

## Documentation Updated
- [x] Class docs for new files (see docs/lib/, docs/sidekiq/, docs/components/)
