# ExternalLink

## Summary
Represents external links for media entities across all domains (music, books, movies, games). Supports various link types including purchase links (Amazon, Bookshop.org), information links (MusicBrainz, Discogs, Goodreads), reviews, and other resources with metadata storage and click tracking capabilities. **NEW (Sept 2025)**: Core polymorphic model for managing external links across the entire platform.

## Associations
- `belongs_to :parent, polymorphic: true` — The entity this link belongs to (Music::Artist, Music::Album, Music::Song, Music::Release)
- `belongs_to :submitted_by, class_name: 'User', optional: true` — Optional user who submitted the link

## Public Methods

### `#increment_click_count!`
Atomically increments the click count for analytics tracking
- Returns: Boolean (success/failure)
- Side effects: Updates click_count field in database
- Used for: Click tracking and analytics

### `#display_price`
Formats price_cents as currency string
- Returns: String (e.g., "$12.99") or nil if no price set
- Example: `link.display_price # => "$24.99"`
- Used for: Admin interface and public display

### `#source_display_name`
Returns human-friendly source name
- Returns: String - humanized enum value or custom source_name
- Example: `link.source_display_name # => "Amazon"` or `"Last.fm"`
- Logic: Returns source_name for 'other' sources, otherwise humanizes enum

## Validations
- `name` — presence required
- `url` — presence required, valid HTTP/HTTPS format using URI regexp
- `price_cents` — positive integer when present
- `source_name` — required when source is 'other'
- `click_count` — non-negative integer

## Scopes
- `public_links` — Returns only publicly visible links (`where(public: true)`)
- `by_source(source)` — Filter by source type
- `by_category(category)` — Filter by link category
- `most_clicked` — Order by click_count descending

## Constants

### Source Enum
Predefined sources for external links:
- `amazon` (0) — Amazon product pages and marketplace
- `goodreads` (1) — Goodreads book pages and reviews
- `bookshop_org` (2) — Bookshop.org independent bookstore links
- `musicbrainz` (3) — MusicBrainz database entries and information
- `discogs` (4) — Discogs marketplace and music database
- `wikipedia` (5) — Wikipedia articles and information pages
- `other` (6) — Custom source (requires source_name field)

### Link Category Enum
Types of external links:
- `product_link` (0) — Purchase/commercial links and marketplaces
- `review` (1) — Review and critique links
- `information` (2) — Informational/reference links and databases
- `misc` (3) — Miscellaneous links that don't fit other categories

## Database Schema
- `name` (string, required) — Display name for the link
- `description` (text) — Optional detailed description
- `url` (string, required) — The external URL (validated format)
- `price_cents` (integer) — Price in cents for commercial links
- `source` (integer, enum) — Predefined source type (0-6)
- `source_name` (string) — Custom source name when source=other
- `link_category` (integer, enum) — Type of link (0-3)
- `parent_type` (string, required) — Polymorphic parent class name
- `parent_id` (bigint, required) — Polymorphic parent record ID
- `submitted_by_id` (bigint) — Optional user who submitted link
- `public` (boolean, default: true) — Public visibility flag
- `click_count` (integer, default: 0) — Analytics click counter
- `metadata` (jsonb, default: '{}') — Flexible JSON data storage

## Indexes
- `parent_type, parent_id` — Polymorphic parent lookup (composite)
- `submitted_by_id` — User lookup (automatically created)
- `source` — Source type filtering
- `public` — Visibility filtering  
- `click_count DESC` — Popular links ordering

## Usage Examples

```ruby
# Create a purchase link
ExternalLink.create!(
  name: "Blackstar (Vinyl)",
  url: "https://amazon.com/blackstar-vinyl",
  price_cents: 2499,
  source: :amazon,
  link_category: :product_link,
  parent: david_bowie_artist,
  public: true
)

# Create an information link with custom source
ExternalLink.create!(
  name: "Artist Profile",
  url: "https://last.fm/music/David+Bowie", 
  source: :other,
  source_name: "Last.fm",
  link_category: :information,
  parent: david_bowie_artist
)

# Query links by parent and type
artist.external_links.public_links.by_category(:product_link)
album.external_links.by_source(:amazon)
ExternalLink.most_clicked.limit(10)
```

## Dependencies
- Rails 8 enum syntax with colon prefix (`enum :source, {...}`)
- PostgreSQL for JSONB metadata field support
- URI library for URL format validation
- Polymorphic association support

## Admin Interface
Fully managed through Avo with:
- Complete CRUD operations (create, read, update, delete)
- Polymorphic parent selection (Music::Artist, Music::Album, etc.)
- Enum dropdowns for source and link_category
- Price display formatting with currency
- Click count readonly display
- Metadata JSON editor with syntax highlighting
- URL validation and clickable links
- Public/private visibility toggle

## Integration Points
- **Music Models**: All Music:: models (Artist, Album, Song, Release) have `has_many :external_links`
- **User System**: Optional submitted_by association for link attribution
- **Analytics**: Click count field for future tracking implementation
- **Search**: Potential future integration with search indexing

## Future Enhancements
- Click tracking controller with redirect endpoint
- Automatic link validation and broken link detection
- Bulk import functionality for external links
- Analytics dashboard for click statistics
- API endpoints for external link management
- Link expiration and archiving system