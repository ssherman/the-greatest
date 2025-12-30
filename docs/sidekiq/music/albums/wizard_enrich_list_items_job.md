# Music::Albums::WizardEnrichListItemsJob

## Summary
Background job that enriches all unverified `ListItem` records for an album list with metadata from OpenSearch and MusicBrainz. Part of the album list wizard Step 3 (Enrich).

## Location
`app/sidekiq/music/albums/wizard_enrich_list_items_job.rb`

## Interface

### `perform(list_id)`
Enriches all unverified list items for the given list.

**Parameters:**
- `list_id` (Integer) - ID of the `Music::Albums::List` to process

**Side Effects:**
- Updates `wizard_state` with progress and stats
- Updates `list_items.metadata` with enrichment data
- Sets `list_items.listable_id` when matches found

## Workflow

1. Find list by ID
2. Validate preconditions (has unverified items)
3. Update wizard_state step status to "running" with progress 0
4. Clear previous enrichment data (idempotent)
5. Iterate through unverified list_items:
   - Call `ListItemEnricher.call(list_item:)`
   - Track stats (opensearch_matches, musicbrainz_matches, not_found)
   - Update progress every 10 items
6. Update wizard_state step status to "completed" with progress 100

## Progress Updates

Progress is updated via `wizard_manager.update_step_status!`:
- Every 10 items processed
- Every 5 seconds (whichever comes first)
- Always at start (0%) and end (100%)

**Metadata tracked:**
```ruby
{
  "processed_items" => 45,
  "total_items" => 100,
  "opensearch_matches" => 30,
  "musicbrainz_matches" => 10,
  "not_found" => 5,
  "enriched_at" => "2025-01-23T15:30:00Z"  # On completion
}
```

## Idempotency

Job is designed to be safely retried:
- Clears enrichment-specific metadata fields before processing
- Resets `listable_id` to nil for items being re-enriched
- Original metadata (title, artists, release_year, etc.) preserved

**Enrichment keys cleared:**
- `album_id`, `album_name`
- `opensearch_match`, `opensearch_score`
- `mb_release_group_id`, `mb_release_group_name`
- `mb_artist_ids`, `mb_artist_names`
- `musicbrainz_match`

## Error Handling

- **Empty list**: Updates wizard_state to failed with "No items to enrich"
- **Individual item failures**: Logged as warning, counted as `not_found`, processing continues
- **Critical failures**: Updates wizard_state to failed, re-raises exception for Sidekiq retry
- **List not found**: Raises `ActiveRecord::RecordNotFound` for Sidekiq retry

## Queue

Uses default Sidekiq queue (no custom queue specified).

## Dependencies

- `Services::Lists::Music::Albums::ListItemEnricher` - Single item enrichment
- `Music::Albums::List` - List model with wizard_manager helpers

## Related Files

- `app/lib/services/lists/music/albums/list_item_enricher.rb` - Service called per item
- `app/controllers/admin/music/albums/list_wizard_controller.rb` - Enqueues this job
- `app/components/admin/music/albums/wizard/enrich_step_component.rb` - UI component
- `test/sidekiq/music/albums/wizard_enrich_list_items_job_test.rb` - 11 tests

## Usage

```ruby
# Enqueue job
Music::Albums::WizardEnrichListItemsJob.perform_async(list.id)

# Check progress via wizard_manager
list.reload
manager = list.wizard_manager
manager.step_status("enrich")    # => "running" | "completed" | "failed"
manager.step_progress("enrich")  # => 0-100
manager.step_metadata("enrich")  # => { "processed_items" => 45, ... }
manager.step_error("enrich")     # => nil or error message
```

## Performance

- OpenSearch queries: ~10ms per item
- MusicBrainz queries: ~200-500ms per item (with rate limiting)
- Progress updates: ~10ms overhead per batch
- Expected completion: < 5 minutes for 100 items
