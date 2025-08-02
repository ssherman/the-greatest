# DataImporters::Music::Artist::Providers::MusicBrainz

## Summary
MusicBrainz provider for Music::Artist data import. Fetches comprehensive artist information from MusicBrainz API including basic details, geographic data, temporal information, and external identifiers.

## Public Methods

### `#populate(artist, query:)`
Main method to populate artist with MusicBrainz data
- Parameters:
  - artist (Music::Artist) - The artist instance to populate
  - query (ImportQuery) - Artist import query with name
- Returns: ProviderResult with success/failure status and populated fields
- Purpose: Fetch and populate comprehensive artist data from MusicBrainz

## Data Population

### Basic Information
- **Name**: Artist/band name (preserves existing if MusicBrainz returns blank)
- **Kind**: Maps MusicBrainz type to internal enum
  - "Group", "Orchestra", "Choir" → "band"
  - "Person", "Character" → "person"
  - Unknown types default to "person"

### Geographic Data
- **Country**: ISO 3166-1 alpha-2 country code from MusicBrainz

### Temporal Data
#### For Persons (kind: "person")
- **born_on**: Full birth date if available (YYYY-MM-DD format)
- **year_died**: Death year extracted from "ended" date

#### For Bands (kind: "band")  
- **year_formed**: Formation year from "begin" date
- **year_disbanded**: Disbandment year from "ended" date

### External Identifiers
- **MusicBrainz ID**: Primary MusicBrainz artist identifier
- **ISNI**: International Standard Name Identifier(s) if available

## Private Methods

### `#search_for_artist(name)`
Searches MusicBrainz API for artist by name
- Returns: Hash with success status and artist data
- Uses Music::Musicbrainz::Search::ArtistSearch service

### `#search_service`
- Returns: Memoized Music::Musicbrainz::Search::ArtistSearch instance
- Purpose: API client for MusicBrainz searches

### `#populate_artist_data(artist, artist_data)`
Populates core artist attributes from MusicBrainz response
- Maps external types to internal enums
- Handles country and life-span data

### `#populate_life_span_data(artist, life_span_data)`
Processes MusicBrainz life-span information
- Handles full dates (YYYY-MM-DD) and partial dates (YYYY)
- Different logic for persons vs bands
- Gracefully handles missing or malformed dates

### `#map_musicbrainz_type_to_kind(mb_type)`
Maps MusicBrainz artist types to internal kind enum
- Case-insensitive mapping
- Defaults to "person" for unknown types

### `#create_identifiers(artist, artist_data)`
Creates external identifier records for the artist
- MusicBrainz ID as primary identifier
- Multiple ISNI identifiers if present

### `#data_fields_populated(artist_data)`
Determines which fields were populated based on available data
- Returns: Array of symbols representing populated fields
- Used for ProviderResult reporting

## Error Handling

### API Failures
- Network errors return failure ProviderResult
- Search failures with error details
- Graceful degradation for partial data

### Data Validation
- Handles missing or malformed dates
- Preserves existing artist name if MusicBrainz returns blank
- Validates data before population

### Exception Handling
All exceptions caught and converted to failure results with descriptive error messages.

## Data Coverage
Typically populates these fields when available:
- `:name` - Artist name
- `:kind` - Person/band classification  
- `:musicbrainz_id` - Primary external identifier
- `:country` - Geographic information
- `:life_span_data` - Formation/birth and dissolution/death dates
- `:isni` - International identifiers

## Return Values

### Success Result
```ruby
ProviderResult.success(
  provider: "DataImporters::Music::Artist::Providers::MusicBrainz",
  data_populated: [:name, :kind, :musicbrainz_id, :country, :life_span_data, :isni]
)
```

### Failure Result
```ruby
ProviderResult.failure(
  provider: "DataImporters::Music::Artist::Providers::MusicBrainz", 
  errors: ["No artists found"]
)
```

## Dependencies
- Music::Musicbrainz::Search::ArtistSearch for API access
- ProviderBase for result creation methods
- Identifier model for external ID storage
- Music::Artist model and validations

## Usage Example
```ruby
provider = DataImporters::Music::Artist::Providers::MusicBrainz.new
artist = Music::Artist.new(name: "Pink Floyd")
query = DataImporters::Music::Artist::ImportQuery.new(name: "Pink Floyd")

result = provider.populate(artist, query: query)
if result.success?
  puts "Populated: #{result.data_populated.join(', ')}"
  puts "Artist: #{artist.name} (#{artist.kind}) from #{artist.country}"
else
  puts "Failed: #{result.errors.join(', ')}"
end
```