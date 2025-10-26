# Music::Albums::RankedCardComponent

## Summary
Reusable ViewComponent for displaying a ranked album as a clickable card. Created to ensure consistent album card rendering across multiple pages (ranked items index, category pages). This component encapsulates the complete album card UI including rank badge, cover art, title, artists, release year, and category tags.

## Purpose
- Maintain consistent album card appearance across the Music domain
- Prevent UI inconsistencies between different album listing pages
- Encapsulate album card markup in a single reusable component
- Simplify view templates by extracting complex card rendering logic

## Initialization

### Parameters
- `ranked_item` (RankedItem, required) - The RankedItem record containing the album and its rank
- `ranking_configuration` (RankingConfiguration, optional) - The ranking configuration for generating album links

### Example Usage
```erb
<%= render Music::Albums::RankedCardComponent.new(
  ranked_item: ranked_item,
  ranking_configuration: @ranking_configuration
) %>
```

## Component Structure

### Card Layout
The component renders a DaisyUI card with:
1. **Cover Art** - Album primary image or placeholder
2. **Rank Badge** - Primary badge with rank number (top left)
3. **Release Year** - Small text display (top right)
4. **Album Title** - Large, bold card title
5. **Artist Names** - Comma-separated artist list
6. **Category Tags** - Up to 3 category badges with "+N more" indicator

### Clickable Behavior
The entire card is a clickable link to the album show page:
- Uses `link_to_album` helper from `Music::DefaultHelper`
- Includes `data: { turbo_frame: "_top" }` to break out of Turbo Frames
- Hover effect: shadow-xl → shadow-2xl transition

**Important:** Category badges inside the card are NOT clickable (plain `<span>` elements) to avoid nested links, which would be invalid HTML.

## Private Methods

### `ranked_item`
Returns the RankedItem passed during initialization.

**Returns:** RankedItem instance

### `ranking_configuration`
Returns the optional ranking configuration passed during initialization.

**Returns:** RankingConfiguration instance or nil

### `album`
Memoized accessor for the album from the ranked item.

**Returns:** Music::Album instance (via `ranked_item.item`)

## Dependencies
- ViewComponent gem
- `Music::DefaultHelper` module (included for helper methods)
  - `link_to_album` - Generates album path with optional ranking configuration
  - `rails_public_blob_url` - Active Storage helper for image URLs
- DaisyUI CSS framework for card styling
- TailwindCSS for utility classes

## UI Elements

### Cover Art Display
- **With image**: Displays album primary image as rounded square with aspect-square ratio
- **Without image**: Shows gray placeholder with "No Image" text
- **Styling**: Full width, rounded-xl, object-cover for proper aspect ratio

### Rank Badge
- **Style**: badge-primary badge-lg with bold font
- **Format**: "#" + rank number (e.g., "#1", "#42")
- **Position**: Top left of card body

### Release Year
- **Display**: Small gray text on top right
- **Conditional**: Only shown if album.release_year exists
- **Styling**: text-sm text-base-content/70

### Artist Names
- **Format**: Comma-separated list (e.g., "Pink Floyd, David Gilmour")
- **Source**: `album.artists.map(&:name).join(", ")`
- **Styling**: text-base-content/80

### Category Tags
- **Limit**: Shows first 3 categories
- **Overflow**: "+N more" badge if more than 3 categories exist
- **Styling**: badge-ghost badge-sm
- **Important**: Plain `<span>` elements, NOT links (prevents nested links)

## Responsive Design
The component is designed to work within grid layouts:
- Scales to full width of grid cell
- Maintains aspect ratio for cover art
- Text wraps appropriately for mobile
- Tested in responsive grids (md:grid-cols-2, lg:grid-cols-3, xl:grid-cols-4)

## Nested Links Prevention
**Critical implementation detail:** Category badges are intentionally non-clickable to prevent nested link HTML structure:
- Outer link: Entire card links to album show page
- Inner content: Category badges are plain `<span>` elements
- Rationale: Nested `<a>` tags are invalid HTML and cause UI rendering bugs

This was discovered and fixed during initial implementation (see [062-music-category-show-page.md](../../../todos/062-music-category-show-page.md) Phase 1 challenges).

## Turbo Frame Compatibility
The component includes `data: { turbo_frame: "_top" }` on the main link to ensure full-page navigation:
- Breaks out of any parent Turbo Frame
- Prevents "no content" errors when clicking cards inside frames
- Ensures proper navigation to album show pages

## Usage Locations
Currently used in:
- `/app/views/music/categories/show.html.erb` - Category overview page (top 10 albums)
- `/app/views/music/albums/categories/show.html.erb` - Album category browsing page
- `/app/views/music/albums/ranked_items/index.html.erb` - Main album rankings page

## Testing
Component tests located at:
- `test/components/music/albums/ranked_card_component_test.rb`

Tests cover:
- Rendering with all album data present
- Rendering with missing cover art (placeholder display)
- Rendering without release year
- Category badge rendering and overflow logic
- Link generation with and without ranking configuration

## Future Enhancements
Potential improvements identified:
- Support for additional badge types (e.g., "Album of the Year")
- Optional compact mode for smaller cards
- Artist count overflow (similar to categories)
- Lazy loading for cover art images
