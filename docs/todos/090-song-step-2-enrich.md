# [090] - Song Wizard: Step 2 - Enrich

## Status
- **Status**: Planned
- **Priority**: High
- **Created**: 2025-01-19
- **Part**: 5 of 10

## Overview
Enrich unverified list_items with OpenSearch/MusicBrainz data. Updates metadata field with song_id, mb_recording_id, etc.

## Acceptance Criteria
- [ ] "Start Enrichment" button enqueues job
- [ ] Progress shows "Enriching 45/100 items..."
- [ ] OpenSearch tried first (fast), MusicBrainz fallback
- [ ] Metadata updated with: song_id, opensearch_match OR mb_recording_id, musicbrainz_match
- [ ] Stats shown: Total, OpenSearch matches, MusicBrainz matches, Not found

## Key Components

### View
**File**: `app/views/admin/music/songs/list_wizard/steps/_enrich.html.erb`
- Stats cards (total, OpenSearch %, MusicBrainz %, missing %)
- Progress bar
- Status text with counts

### Job
**File**: `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb`
Updates metadata on each item (see [087] for full code)

### Service
**File**: `app/lib/services/lists/music/songs/item_enricher.rb`
```ruby
# Contract
def call
  # 1. Try OpenSearch (local DB search)
  # 2. If no match, try MusicBrainz API
  # 3. Update item.metadata with results
  # Returns: Result.new(success?, data: {source:, song:, score:})
end
```

**Logic**:
- OpenSearch: Search by title + artists, min_score 5.0
- MusicBrainz: Search recording API, extract MBID + artist MBIDs
- Update metadata atomically per item

## Tests
- [ ] Job enriches all unverified items
- [ ] OpenSearch match updates metadata correctly
- [ ] MusicBrainz fallback works
- [ ] Progress updates every 10 items
- [ ] Stats calculation accurate

## Related
- **Previous**: [089] Step 1: Parse
- **Next**: [091] Step 3: Validation
- **Reference**: Existing enricher patterns in `app/lib/services/lists/music/songs/items_json_enricher.rb`
