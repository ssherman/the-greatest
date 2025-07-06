# List

## Summary
Represents a list in the system. Core model for aggregating and ranking content across all media domains (books, movies, music, games). Uses Single Table Inheritance (STI) to support domain-specific logic while maintaining a shared database structure.

## Associations
- `has_many :list_items, dependent: :destroy` - Items contained in this list
- `belongs_to :user` - User who submitted the list (future)

## Public Methods
No custom public methods defined. Inherits standard ActiveRecord methods.

## Validations
- `name` - presence required
- `type` - presence required (for STI functionality)
- `status` - presence required
- `url` - format validation (URI::regexp) when present, allows blank

## Scopes
- `approved` - Returns lists with approved status
- `high_quality` - Returns lists marked as high quality sources
- `by_year(year)` - Returns lists published in the specified year
- `yearly_awards` - Returns lists that are yearly awards

## Constants
None defined.

## Callbacks
None defined.

## Dependencies
- Rails STI functionality for type-based inheritance
- URI module for URL validation

## STI Subclasses
The List model uses Single Table Inheritance with the following subclasses:

### Books::List
Domain-specific list for books content.

### Movies::List
Domain-specific list for movies content.

### Music::List
Domain-specific list for music content.

### Games::List
Domain-specific list for games content.

## Database Schema
- `id` - Primary key
- `type` - STI discriminator (string, not null)
- `name` - List name (string, not null)
- `description` - List description (text)
- `source` - Source of the list (string)
- `url` - URL to the original list (string)
- `status` - Approval status (integer, not null, default: 0)
- `estimated_quality` - Quality score (integer, not null, default: 0)
- `high_quality_source` - Whether source is high quality (boolean)
- `category_specific` - Whether list is category-specific (boolean)
- `location_specific` - Whether list is location-specific (boolean)
- `year_published` - Year the list was published (integer)
- `yearly_award` - Whether list is a yearly award (boolean)
- `number_of_voters` - Number of voters in the list (integer)
- `voter_count_unknown` - Whether voter count is unknown (boolean)
- `voter_names_unknown` - Whether voter names are unknown (boolean)
- `formatted_text` - Formatted text content (text)
- `raw_html` - Raw HTML content (text)
- `created_at` - Creation timestamp
- `updated_at` - Update timestamp

## Status Values
- `0` - unapproved
- `1` - approved
- `2` - rejected

## Usage Examples
```ruby
# Create a basic list
list = List.create!(name: "My List", type: "List", status: :unapproved)

# Create a domain-specific list
books_list = Books::List.create!(name: "Best Books 2023", status: :approved)

# Query approved lists
approved_lists = List.approved

# Query high quality lists
high_quality_lists = List.high_quality

# Query lists by year
lists_2023 = List.by_year(2023)

# Query yearly awards
award_lists = List.yearly_awards

# Access list items
list.list_items.ordered

# Add items to a list
album = Music::Album.first
list.list_items.create!(listable: album, position: 1)
``` 