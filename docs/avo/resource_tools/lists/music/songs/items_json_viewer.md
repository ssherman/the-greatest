# Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer

## Summary
Avo resource tool that displays the items_json field for Music::Songs::List records in a formatted, user-friendly table with statistics dashboard. Provides visual feedback on enrichment progress, missing data, and AI validation results.

## Purpose
Allows admins to:
- View enriched song data from items_json in a structured table format
- Monitor enrichment progress with MusicBrainz data
- Identify songs missing MusicBrainz matches (gray background)
- See AI-flagged invalid matches (red background)
- Review validation status before importing songs

## Location
`app/avo/resource_tools/lists/music/songs/items_json_viewer.rb`

## Parent Class
- Inherits from `Avo::BaseResourceTool`

## Configuration

### Class Attributes
- `self.name` - "Items JSON Viewer"
- `self.partial` - Points to ERB template at `avo/resource_tools/lists/music/songs/items_json_viewer`

## View Template

### Statistics Dashboard
Displays four statistics cards:

1. **Total Songs** - Total count from items_json["songs"] array
2. **Enriched with MusicBrainz** - Count of songs with mb_recording_id present, with enrichment percentage
3. **Missing MusicBrainz Data** - Count and percentage of songs without mb_recording_id
4. **AI Validated** - Count of songs that have been AI-validated, with count of invalid matches

### Data Table

#### Columns
1. **Status** - Badge showing validation state (✓ valid, ✗ missing, ⚠ invalid)
2. **Rank** - Song rank from list
3. **Title** - Song title
4. **Artists** - Comma-separated artist names
5. **Year** - Release year
6. **MusicBrainz Recording** - Recording ID and name (if enriched)
7. **MusicBrainz Artists** - Artist IDs and names from MusicBrainz
8. **Database Song** - Local database song ID and name (if exists)

#### Visual Indicators
- **Gray background** - Song missing MusicBrainz data (no mb_recording_id)
- **Red background** - AI flagged as invalid match (ai_match_invalid: true)
- Red takes precedence over gray when both conditions present

### Empty State
Shows info alert when:
- items_json is nil
- items_json["songs"] is missing or empty

## Data Structure Expected

### items_json Format
```json
{
  "songs": [
    {
      "rank": 1,
      "title": "Come Together",
      "artists": ["The Beatles"],
      "release_year": 1969,
      "mb_recording_id": "e3f3c2d4-55c2-4d28-bb47-71f42f2a5ccc",
      "mb_recording_name": "Come Together",
      "mb_artist_ids": ["b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d"],
      "mb_artist_names": ["The Beatles"],
      "song_id": 123,
      "song_name": "Come Together",
      "ai_match_invalid": true
    }
  ]
}
```

### Field Usage
- **rank** - Used for sorting rows
- **title** - Original song title from list
- **artists** - Original artist names (array)
- **release_year** - Original release year
- **mb_recording_id** - MusicBrainz recording UUID (enrichment indicator)
- **mb_recording_name** - MusicBrainz recording name
- **mb_artist_ids** - MusicBrainz artist UUIDs (array)
- **mb_artist_names** - MusicBrainz artist names (array)
- **song_id** - Local database song ID (if imported)
- **song_name** - Local database song name
- **ai_match_invalid** - Boolean flag from AI validation (optional)

## Registration
Registered in `Avo::Resources::MusicSongsList`:
```ruby
def fields
  super
  tool Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer
end
```

## Related Components
- **Enrichment Service** - `Services::Lists::Music::Songs::ItemsJsonEnricher` populates the data
- **AI Validation** - `Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask` adds ai_match_invalid flags
- **Avo Action** - `Avo::Actions::Lists::Music::Songs::ValidateItemsJson` triggers validation

## Usage Workflow
1. List created with items_json from AI parsing (task 027)
2. Enrich items_json action populates MusicBrainz fields (task 064)
3. Items JSON Viewer shows enrichment progress
4. Validate items_json action flags invalid matches (this task)
5. Items JSON Viewer highlights flagged songs in red
6. Admin reviews before running import action

## Pattern Source
Based on `Avo::ResourceTools::Lists::Music::Albums::ItemsJsonViewer` (task 053) with adaptations for song-specific fields (mb_recording_id vs mb_release_group_id).

## Testing
No automated tests required per project policy. Resource tools are view-layer components tested through manual inspection in Avo admin interface.

## Dependencies
- DaisyUI CSS framework for statistics cards and badges
- Avo::PanelComponent for consistent styling
- Tailwind CSS for responsive layout
