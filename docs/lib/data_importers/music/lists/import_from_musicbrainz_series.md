# DataImporters::Music::Lists::ImportFromMusicbrainzSeries

## Summary
Service object that imports albums from a MusicBrainz series and creates list items for a Music::Albums::List. Retrieves series data from MusicBrainz API, imports each related album using existing importers, and creates positioned list items while avoiding duplicates.

## Usage

### Class Method
```ruby
result = ImportFromMusicbrainzSeries.call(list: music_albums_list)
```

### Instance Method
```ruby
importer = ImportFromMusicbrainzSeries.new(list: music_albums_list)
result = importer.call
```

## Parameters
- `list` (Music::Albums::List) - The list to import albums into. Must have `musicbrainz_series_id` set.

## Return Value
Returns a hash with the following structure:
```ruby
{
  success: true/false,
  message: "Imported X of Y albums",
  imported_count: 5,
  total_count: 8,
  results: [
    {
      album: Music::Album instance,
      position: 1,
      release_group_id: "musicbrainz-id",
      success: true
    },
    # ... more results
  ]
}
```

## Validations
- List must be an instance of `Music::Albums::List`
- List must have `musicbrainz_series_id` present

## Process Flow
1. **Validate List** - Ensures list is valid Music::Albums::List with series ID
2. **Fetch Series Data** - Retrieves series data from MusicBrainz API using SeriesSearch
3. **Extract Release Groups** - Parses relations to find release group references with positions
4. **Import Albums** - Uses existing Album::Importer for each release group
5. **Create List Items** - Creates positioned list items, skipping duplicates

## Error Handling
- Returns failure result for invalid lists (catches ArgumentError)
- Gracefully handles series API failures
- Continues processing when individual album imports fail
- Logs detailed information about failures

## Dependencies
- `Music::Musicbrainz::Search::SeriesSearch` - For fetching series data from MusicBrainz
- `DataImporters::Music::Album::Importer` - For importing individual albums
- `Music::Albums::List` - Target list model
- `Music::Album` - Album model with identifier scopes

## Side Effects
- Creates new `Music::Album` records for albums not already in database
- Creates new `ListItem` records linking albums to the list
- May create associated artists, identifiers, and categories via Album::Importer
- Logs import progress and failures to Rails logger

## Usage Patterns
Typically called via background job (`ImportListFromMusicbrainzSeriesJob`) triggered from AVO admin interface action.

## Related Classes
- `ImportListFromMusicbrainzSeriesJob` - Background job wrapper
- `Avo::Actions::Lists::ImportFromMusicbrainzSeries` - Admin interface action
- `DataImporters::Music::Album::Importer` - Used for individual album imports
- `Music::Musicbrainz::Search::SeriesSearch` - External API integration