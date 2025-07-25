# List

## Summary
Represents a list in the system. Core model for aggregating and ranking content across all media domains (books, movies, music, games). Uses Single Table Inheritance (STI) to support domain-specific logic while maintaining a shared database structure.

## Associations
- `has_many :list_items, dependent: :destroy` - Items contained in this list
- `belongs_to :submitted_by, class_name: "User", optional: true` - User who submitted the list (optional)
- `has_many :list_penalties, dependent: :destroy` - Join table for penalties associated with this list
- `has_many :penalties, through: :list_penalties` - Penalties that apply to this list
- `has_many :ai_chats, as: :parent, dependent: :destroy` - AI chat conversations about this list

## Public Methods

### `#has_penalties?`
Returns true if this list has any penalties associated with it.
- Returns: Boolean

### `#global_penalties`
Returns penalties that are globally available (not user-specific).
- Returns: ActiveRecord::Relation of Penalty objects

### `#user_penalties`
Returns penalties that are user-specific (not global).
- Returns: ActiveRecord::Relation of Penalty objects

**Note:** Penalty calculation logic has been moved to service objects (`Rankings::WeightCalculatorV1`) following "Skinny Models, Fat Services" principles. The model only provides data access methods.

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

## Related Services
- `Rankings::WeightCalculatorV1` - Handles penalty calculations and weight determination
- `Rankings::BulkWeightCalculator` - Processes multiple lists for weight calculation
- `Rankings::DisplayWeightService` - Formats weight information for UI display (when implemented)

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
- `submitted_by_id` - User who submitted the list (optional, foreign key to users)
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

# Assign a submitting user
user = User.first
list = List.create!(name: "User Submitted List", submitted_by: user, status: :approved)

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

# Check for penalties (data access only)
list.has_penalties?            # => true/false
list.global_penalties          # => ActiveRecord::Relation
list.user_penalties           # => ActiveRecord::Relation

# For penalty calculations, use service objects:
# calculator = Rankings::WeightCalculator.for_ranked_list(ranked_list)
# weight = calculator.call
``` 