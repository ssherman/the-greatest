# Admin::Music::MusicbrainzSearchController

## Summary
JSON API controller for MusicBrainz search functionality within the admin interface. Provides artist autocomplete for features like artist import and list wizard artist linking.

## Purpose
- Centralized MusicBrainz search endpoints for admin features
- Enables artist autocomplete across multiple admin workflows
- Returns search results formatted for `AutocompleteComponent` consumption

## Inheritance
- Inherits from: `Admin::Music::BaseController`

## Routes

| Verb | Path | Action | Route Helper |
|------|------|--------|--------------|
| GET | `/admin/musicbrainz/artists` | `artists` | `admin_musicbrainz_artists_path` |

## Public Methods

### `#artists`
Searches MusicBrainz for artists matching a query string.

**Parameters:**
- `q` (String, required) - Search query, minimum 2 characters

**Response:** JSON array of matching artists
```json
[
  {
    "value": "83d91898-7763-47d7-b03b-b92132375c47",
    "text": "Pink Floyd (Group from United Kingdom)"
  }
]
```

**Edge Cases:**
- Returns `[]` if query is blank or less than 2 characters
- Returns `[]` if MusicBrainz API fails (graceful degradation)
- Returns `[]` if no results found

## Private Methods

### `#format_artist_display(artist)`
Formats a MusicBrainz artist hash for display in autocomplete.

**Format:** `"Artist Name (Type from Location)"`

**Examples:**
- `"The Beatles (Group from Liverpool)"` - type and disambiguation
- `"Pink Floyd (Group from United Kingdom)"` - type and country
- `"Cher (Person)"` - type only, no location
- `"Unknown Artist"` - no metadata

## Dependencies
- `Music::Musicbrainz::Search::ArtistSearch` - MusicBrainz API client

## Usage

Used by `AutocompleteComponent` in:
- Artist import modal (`app/views/admin/music/artists/index.html.erb`)
- List wizard artist linking (`app/views/admin/music/*/list_items_actions/modals/_search_musicbrainz_artists.html.erb`)

**Example autocomplete usage:**
```erb
<%= render AutocompleteComponent.new(
  name: "musicbrainz_id",
  url: admin_musicbrainz_artists_path,
  placeholder: "Search MusicBrainz for artist...",
  required: true
) %>
```

## Related Classes
- `Admin::Music::BaseController` - Parent class
- `Music::Musicbrainz::Search::ArtistSearch` - MusicBrainz API integration
- `AutocompleteComponent` - Frontend component consuming this endpoint

## Related Specs
- Spec 119: Admin Import Artist from MusicBrainz
- Spec 120: Refactor MusicBrainz Search Controller (created this controller)

## File Location
`/home/shane/dev/the-greatest/web-app/app/controllers/admin/music/musicbrainz_search_controller.rb`
