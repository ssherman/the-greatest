# Services::Lists::Music::Songs::ListItemEnricher

## Summary
Enriches a single `ListItem` with metadata from OpenSearch (local database) and MusicBrainz (external API). Used by the song list wizard to match parsed songs to existing `Music::Song` records or gather MusicBrainz IDs for later import.

## Location
`app/lib/services/lists/music/songs/list_item_enricher.rb`

## Interface

### `self.call(list_item:)`
Class method entry point for enriching a single list item.

**Parameters:**
- `list_item` (ListItem) - An unverified ListItem with metadata containing `title` and `artists`

**Returns:** Hash with enrichment result
```ruby
{
  success: true/false,
  source: :opensearch | :musicbrainz | :not_found | :error,
  song_id: Integer | nil,
  data: Hash  # Enrichment data added to metadata
}
```

## Enrichment Strategy

1. **OpenSearch First** - Fast local database search (~10ms per item)
   - Uses `Search::Music::Search::SongByTitleAndArtists.call`
   - Requires min_score of 5.0 for match
   - If match found, sets `listable_id` and updates metadata

2. **MusicBrainz Fallback** - External API (~200-500ms per item)
   - Uses `Music::Musicbrainz::Search::RecordingSearch`
   - Searches by artist name and title
   - If recording found, checks for existing song by MBID
   - Updates metadata with MusicBrainz IDs for later import

3. **No Match** - Returns `{success: false, source: :not_found}`

## Metadata Updates

### OpenSearch Match
```ruby
{
  "song_id" => 123,
  "song_name" => "Come Together",
  "opensearch_match" => true,
  "opensearch_score" => 15.5
}
```

### MusicBrainz Match (song exists locally)
```ruby
{
  "song_id" => 456,
  "song_name" => "Come Together",
  "mb_recording_id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_recording_name" => "Come Together",
  "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names" => ["The Beatles"],
  "musicbrainz_match" => true
}
```

### MusicBrainz Match (song does not exist locally)
```ruby
{
  "mb_recording_id" => "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_recording_name" => "Come Together",
  "mb_artist_ids" => ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
  "mb_artist_names" => ["The Beatles"],
  "musicbrainz_match" => true
}
```

## Error Handling

- Missing `title` or `artists` in metadata: Returns `not_found` result
- OpenSearch errors: Logs error, falls back to MusicBrainz
- MusicBrainz errors: Logs error with full backtrace, returns `not_found`
- All exceptions caught and logged at appropriate level

## Logging

- **INFO**: MusicBrainz search query and result count
- **WARN**: MusicBrainz API errors
- **ERROR**: Exception details with backtrace
- **DEBUG**: Successful match details

## Dependencies

- `Search::Music::Search::SongByTitleAndArtists` - OpenSearch query
- `Music::Musicbrainz::Search::RecordingSearch` - MusicBrainz API client
- `Music::Song.with_identifier` - MBID lookup scope

## Related Files

- `app/lib/services/lists/music/songs/items_json_enricher.rb` - Similar pattern for items_json enrichment
- `app/sidekiq/music/songs/wizard_enrich_list_items_job.rb` - Job that calls this service
- `test/lib/services/lists/music/songs/list_item_enricher_test.rb` - 13 tests

## Usage Example

```ruby
list_item = ListItem.find(123)
result = Services::Lists::Music::Songs::ListItemEnricher.call(list_item: list_item)

if result[:success]
  puts "Matched via #{result[:source]}: song_id=#{result[:song_id]}"
else
  puts "No match found"
end
```
