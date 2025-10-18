# [053] - Items JSON Viewer Resource Tool

## Status
- **Status**: Not Started
- **Priority**: Medium
- **Created**: 2025-10-18
- **Started**:
- **Completed**:
- **Developer**:

## Overview
Create an Avo resource tool that displays the `items_json` field on `Music::Albums::List` records as a formatted, readable table with validation highlighting and statistics. This will make it easy to review enrichment results from the items_json enricher service and identify albums missing MusicBrainz data.

## Context
After implementing the items_json enricher service (task 052), we need a user-friendly way to review the enrichment results. The `items_json` field contains complex nested JSON data with multiple fields per album:
- Original parsed data: `rank`, `title`, `artists`, `release_year`
- Enriched MusicBrainz data: `mb_release_group_id`, `mb_release_group_name`, `mb_artist_ids`, `mb_artist_names`
- Database references: `album_id`, `album_name`

Currently, reviewing this data requires:
1. Opening the List record in Avo
2. Viewing the raw JSON in the items_json field
3. Manually parsing the JSON to identify missing or incomplete data

This is time-consuming and error-prone. An Avo resource tool can present this data in a clean, scannable table format with visual indicators for data quality issues.

## Requirements
- [ ] Create Avo resource tool that displays on `Music::Albums::List` show pages
- [ ] Render items_json data as an HTML table with columns for all fields
- [ ] Display statistics at the top (total albums, enriched count, missing data count)
- [ ] Highlight rows missing `mb_release_group_id` in red
- [ ] Show all relevant fields: rank, title, artists, year, MusicBrainz IDs/names, album ID/name
- [ ] Handle missing or null fields gracefully
- [ ] Make the table sortable by rank (default)
- [ ] Add to `Music::Albums::List` Avo resource
- [ ] Handle edge cases (empty items_json, null albums array, etc.)

## Technical Approach

### Avo Resource Tool Implementation

**Location**: `app/avo/resource_tools/lists/music/albums/items_json_viewer.rb`

**Structure**:
```ruby
class Avo::ResourceTools::Lists::Music::Albums::ItemsJsonViewer < Avo::BaseResourceTool
  self.name = "Items JSON Viewer"
  self.partial = "avo/resource_tools/lists/music/albums/items_json_viewer"
end
```

### Rails Partial

**Location**: `app/views/avo/resource_tools/lists/music/albums/_items_json_viewer.html.erb`

**Responsibilities**:
1. Extract `items_json["albums"]` array from the resource
2. Calculate statistics:
   - Total album count
   - Enriched count (albums with `mb_release_group_id`)
   - Missing count (albums without `mb_release_group_id`)
3. Render statistics summary at top
4. Render HTML table with columns:
   - Rank
   - Title
   - Artists (join array with ", ")
   - Release Year
   - MusicBrainz Release Group (ID + Name)
   - MusicBrainz Artists (IDs + Names)
   - Database Album (ID + Name)
   - Status indicator (✓ or ✗)
5. Apply CSS class to highlight rows missing `mb_release_group_id`
6. Handle edge cases (empty/null data)

### CSS Styling

**Location**: `app/assets/stylesheets/avo_custom.css` (or create if doesn't exist)

**Styles needed**:
- Statistics box styling (border, padding, background)
- Table styling (borders, header styling, row striping)
- Red highlighting for incomplete rows (`.missing-mb-data { background-color: #fee; }`)
- Status indicator styling (green checkmark, red X)

### Resource Registration

**Location**: `app/avo/resources/music_albums_list.rb`

Add to existing resource:
```ruby
def tools
  tool Avo::ResourceTools::Lists::Music::Albums::ItemsJsonViewer
end
```

## Dependencies
- Existing: `Music::Albums::List` model with `items_json` field
- Existing: Avo 3.x framework
- Existing: Items JSON enrichment from task 052
- New: CSS file for custom styling (if doesn't exist)

## Acceptance Criteria
- [ ] Resource tool appears on `Music::Albums::List` show pages
- [ ] Tool only appears when `items_json` is present (not for empty lists)
- [ ] Statistics show correct counts (total, enriched, missing)
- [ ] Table displays all album entries from items_json
- [ ] All fields are displayed in readable format (arrays joined, nulls handled)
- [ ] Rows missing `mb_release_group_id` are highlighted in red
- [ ] Status indicator shows ✓ for enriched albums, ✗ for missing data
- [ ] Table is readable and properly styled
- [ ] Edge cases handled (empty albums array, null values, missing fields)
- [ ] Tool works for lists with 1, 10, 50+ albums

## Design Decisions

### 1. Resource Tool vs Custom Field
**Decision**: Use Avo resource tool instead of custom field.
**Rationale**: Resource tools are designed for displaying custom content on show pages. Custom fields are better for individual field rendering. A tool gives us complete layout control and can display summary statistics.
**Trade-off**: Resource tools require a separate partial, but provide more flexibility.

### 2. Statistics Placement
**Decision**: Show statistics at the top of the tool, above the table.
**Rationale**: Users want to quickly see overall status before diving into individual albums. This follows the pattern of "summary first, details second."
**Format**: "Showing 20 albums: 15 enriched (75%), 5 missing MusicBrainz data (25%)"

### 3. Red Highlighting Strategy
**Decision**: Highlight entire row in light red (`background-color: #fee`) when `mb_release_group_id` is missing.
**Rationale**: Whole-row highlighting is more noticeable than cell-level highlighting. Light red (#fee) provides clear visual distinction without being overwhelming.
**Alternative Considered**: Only highlight the MusicBrainz ID cell (rejected - less visible).

### 4. Column Selection
**Decision**: Show all available fields from items_json in the table.
**Rationale**: Users need to see both original parsed data and enriched data to verify correctness. Hiding fields would require toggling or multiple views.
**Columns**: Rank, Title, Artists, Year, MB Release Group, MB Artists, Album (DB), Status

### 5. Visibility Control
**Decision**: Only show tool when `items_json` has content.
**Rationale**: Tool is not useful for lists without items_json. Reduces visual clutter on unenriched lists.
**Implementation**: Check in partial: `if resource.record.items_json.present? && resource.record.items_json["albums"]&.any?`

### 6. Sortability
**Decision**: Render table in rank order (sorted by `rank` field from items_json).
**Rationale**: Lists are inherently ordered by rank. Users expect to see albums in list order.
**Future Enhancement**: Could add JavaScript-based column sorting if needed.

### 7. Multi-Artist Display
**Decision**: Join artist arrays with ", " separator.
**Rationale**: Matches common convention for listing multiple artists. Compact and readable.
**Example**: `["The Beatles", "Tony Sheridan"]` → "The Beatles, Tony Sheridan"

### 8. Status Indicator
**Decision**: Add visual status indicator (✓/✗) in addition to row highlighting.
**Rationale**: Provides quick scannable column for data quality. Redundant with highlighting but improves accessibility.
**Implementation**: Unicode characters (✓ = U+2713, ✗ = U+2717)

## Implementation Notes

*[This section will be filled out during/after implementation]*

### Approach Taken


### Key Files Changed


### Challenges Encountered


### Deviations from Plan


### Code Examples


### Testing Approach


### Performance Considerations


### Future Improvements


### Lessons Learned


### Related PRs


### Documentation Updated
- [ ] This task file updated with implementation notes
- [ ] Code includes inline documentation
