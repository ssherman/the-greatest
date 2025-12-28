# Services::Lists::Music::Albums::ListItemEnricher

## Summary
Enriches a single `ListItem` with metadata from OpenSearch (local database) and MusicBrainz (external API). Used by the album list wizard to match parsed albums to existing `Music::Album` records or gather MusicBrainz release group IDs for later import.

## Location
`app/lib/services/lists/music/albums/list_item_enricher.rb`

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
  album_id: Integer | nil,
  data: Hash  # Enrichment data added to metadata
}
```

## Enrichment Strategy

1. **OpenSearch First** - Fast local database search (~10ms per item)
   - Uses `Search::Music::Search::AlbumByTitleAndArtists.call`
   - Requires min_score of 5.0 for match
   - If match found, sets `listable_id` and updates metadata

2. **MusicBrainz Fallback** - External API (~200-500ms per item)
   - Uses `Music::Musicbrainz::Search::ReleaseGroupSearch`
   - Searches by artist name and title
   - If release group found, checks for existing album by MBID
   - Updates metadata with MusicBrainz IDs for later import

3. **No Match** - Returns `{success: false, source: :not_found}`

## Metadata Updates

### OpenSearch Match
```ruby
{
  "album_id" => 123,
  "album_name" => "The Dark Side of the Moon",
  "opensearch_match" => true,
  "opensearch_score" => 15.5
}
```

### MusicBrainz Match (album exists locally)
```ruby
{
  "album_id" => 456,
  "album_name" => "The Dark Side of the Moon",
  "mb_release_group_id" => "a1b2c3d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_release_group_name" => "The Dark Side of the Moon",
  "mb_artist_ids" => ["83d91898-7763-47d7-b03b-b92132375c47"],
  "mb_artist_names" => ["Pink Floyd"],
  "musicbrainz_match" => true
}
```

### MusicBrainz Match (album does not exist locally)
```ruby
{
  "mb_release_group_id" => "a1b2c3d4-55c2-4d28-bb47-71f42f2a5ccc",
  "mb_release_group_name" => "The Dark Side of the Moon",
  "mb_artist_ids" => ["83d91898-7763-47d7-b03b-b92132375c47"],
  "mb_artist_names" => ["Pink Floyd"],
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

- `Search::Music::Search::AlbumByTitleAndArtists` - OpenSearch query
- `Music::Musicbrainz::Search::ReleaseGroupSearch` - MusicBrainz API client
- `Music::Album.with_musicbrainz_release_group_id` - MBID lookup scope

## Related Files

- `app/lib/services/lists/music/songs/list_item_enricher.rb` - Songs version (pattern reference)
- `app/sidekiq/music/albums/wizard_enrich_list_items_job.rb` - Job that calls this service
- `test/lib/services/lists/music/albums/list_item_enricher_test.rb` - 9 tests

## Usage Example

```ruby
list_item = ListItem.find(123)
result = Services::Lists::Music::Albums::ListItemEnricher.call(list_item: list_item)

if result[:success]
  puts "Matched via #{result[:source]}: album_id=#{result[:album_id]}"
else
  puts "No match found"
end
```
