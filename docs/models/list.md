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

### `#parse_with_ai!`
Triggers AI-powered parsing of the list's raw HTML content into structured data.
- Returns: Hash with success status and extracted data or error message
- Side effects: Updates simplified_html and items_json fields on success
- Uses: Services::Lists::ImportService for orchestration

### `.median_list_count(type:)` *(Class Method)*
Calculates the median number of items across all lists of a specific type
- Parameters: type (String) - List type to filter by (e.g., "Music::Albums::List")
- Returns: Numeric median count used for ranking algorithm normalization
- Used by: ItemRankings calculator services for algorithm optimization

**Note:** Penalty calculation logic has been moved to service objects (`Rankings::WeightCalculatorV1`) following "Skinny Models, Fat Services" principles. The model only provides data access methods.

## Validations
- `name` - presence required
- `type` - presence required (for STI functionality)
- `status` - presence required
- `url` - format validation (URI::regexp) when present, allows blank
- `num_years_covered` - numericality validation (greater than 0, only integer), allows nil

## Scopes
- `approved` - Returns lists with approved status
- `high_quality` - Returns lists marked as high quality sources
- `by_year(year)` - Returns lists published in the specified year
- `yearly_awards` - Returns lists that are yearly awards

## Constants
None defined.

## Callbacks
- `before_save :auto_simplify_html, if: :should_simplify_html?` - Automatically simplifies HTML when raw_html is present or changed

## Dependencies
- Rails STI functionality for type-based inheritance
- URI module for URL validation

## Related Services
- `Rankings::WeightCalculatorV1` - Handles penalty calculations and weight determination
- `Rankings::BulkWeightCalculator` - Processes multiple lists for weight calculation
- `Rankings::DisplayWeightService` - Formats weight information for UI display (when implemented)
- `Services::Lists::ImportService` - Orchestrates HTML parsing and AI extraction workflow
- `Services::Html::SimplifierService` - Cleans and simplifies HTML content for AI processing
- `DataImporters::Music::Lists::ImportFromMusicbrainzSeries` - Imports albums from MusicBrainz series (Music::Albums::List only)

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
- `num_years_covered` - Number of years this list covers for temporal penalty calculations (integer)
- `formatted_text` - Formatted text content (text)
- `raw_html` - Raw HTML content (text)
- `simplified_html` - Simplified HTML content for AI parsing (text)
- `items_json` - Structured JSON data extracted from HTML (jsonb)
- `musicbrainz_series_id` - MusicBrainz Series ID for automatic import (string, Music::Albums::List only)
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

# AI-powered list processing (HTML is automatically simplified on save)
list = List.find(123)
list.raw_html = "<ul><li>Item 1</li></ul>"  # Setting raw_html triggers automatic simplification
list.save!                                   # simplified_html is now populated automatically

result = list.parse_with_ai!                 # Extract structured data

if result[:success]
  puts "Extracted data: #{list.items_json}"
else
  puts "Parsing failed: #{result[:error]}"
end
``` 