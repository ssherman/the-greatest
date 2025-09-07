# Music::Albums::List

## Summary
STI subclass of List specifically for music album rankings and collections. Inherits all functionality from the base List model with additional music-specific features including MusicBrainz series integration for automatic album imports.

## Inheritance
Extends `List` via Single Table Inheritance (STI) with `type = 'Music::Albums::List'`.

## Associations
Inherits all associations from List, plus:
- `has_many :list_items` - Items containing Music::Album objects
- Uses polymorphic `listable` association through ListItem to associate with Music::Album records

## Domain-Specific Features

### MusicBrainz Series Import
Music::Albums::List supports automatic import of album rankings from MusicBrainz series data.

#### Fields
- `musicbrainz_series_id` (String) - MusicBrainz Series ID for automatic album imports

#### Import Process
1. Admin sets `musicbrainz_series_id` in AVO interface
2. Admin triggers "Import from MusicBrainz Series" action
3. Background job (`ImportListFromMusicbrainzSeriesJob`) processes the import
4. Service (`DataImporters::Music::Lists::ImportFromMusicbrainzSeries`) fetches series data and imports albums
5. Albums are imported using existing `DataImporters::Music::Album::Importer`
6. ListItems are created with proper positioning based on series data

## Public Methods
Inherits all methods from List. No additional public methods specific to this subclass.

## Validations
Inherits all validations from List. No additional validations specific to this subclass.

## Scopes
Inherits all scopes from List. Can be filtered by type:
```ruby
Music::Albums::List.all
# or
List.where(type: 'Music::Albums::List')
```

## Usage Examples

### Creating a Music Albums List
```ruby
list = Music::Albums::List.create!(
  name: "Rolling Stone's 500 Greatest Albums",
  description: "Classic album rankings",
  status: :approved,
  musicbrainz_series_id: "series-uuid-from-musicbrainz"
)
```

### Adding Albums Manually
```ruby
album = Music::Album.find_by(title: "The Dark Side of the Moon")
list.list_items.create!(listable: album, position: 1)
```

### Triggering MusicBrainz Import
```ruby
# Via background job (recommended)
ImportListFromMusicbrainzSeriesJob.perform_async(list.id)

# Direct service call (synchronous)
result = DataImporters::Music::Lists::ImportFromMusicbrainzSeries.call(list: list)
```

### Accessing Album Items
```ruby
# Get all albums in the list
albums = list.list_items.includes(:listable).map(&:listable)

# Get ordered albums
ordered_albums = list.list_items.order(:position).includes(:listable).map(&:listable)
```

## Dependencies
- Inherits all dependencies from List
- `Music::Album` model for listable items
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` for MusicBrainz integration
- `ImportListFromMusicbrainzSeriesJob` for background processing

## Related Classes
- `List` - Base STI class
- `ListItem` - Join model for album associations
- `Music::Album` - Domain model for album data
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Import service
- `ImportListFromMusicbrainzSeriesJob` - Background job
- `Avo::Actions::Lists::ImportFromMusicbrainzSeries` - Admin action

## Admin Interface (AVO)
Available through AVO with custom resource (`Avo::Resources::MusicAlbumsList`) that includes:
- Display of `musicbrainz_series_id` field
- "Import from MusicBrainz Series" action
- Custom list_items display with position and album title