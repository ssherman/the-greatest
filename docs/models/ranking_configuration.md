# RankingConfiguration

## Summary
Represents a configuration for ranking algorithms across all media types (books, movies, games, music). This model stores algorithm parameters, penalty settings, and metadata for a ranked list aggregation. Supports inheritance, global/user-specific configs, and Single Table Inheritance (STI) for media-specific logic.

## Associations
- `belongs_to :inherited_from, class_name: 'RankingConfiguration', optional: true`  
  The configuration this one was cloned from (for monthly snapshots or versioning).
- `has_many :inherited_configurations, class_name: 'RankingConfiguration', foreign_key: :inherited_from_id, dependent: :nullify`  
  All configurations that have inherited from this one.
- `belongs_to :user, optional: true`  
  The user who created this configuration (null for global configs).
- `belongs_to :primary_mapped_list, class_name: 'List', optional: true`  
  The main mapped list for yearly aggregations (e.g., "Top 100 of 2025").
- `belongs_to :secondary_mapped_list, class_name: 'List', optional: true`  
  The secondary mapped list for yearly aggregations (e.g., "Honorable Mention").
- `has_many :ranked_items, dependent: :destroy`  
  All ranked items (books, movies, albums, etc.) associated with this configuration. Destroyed if the configuration is deleted.
- `has_many :ranked_lists, dependent: :destroy`  
  All ranked lists associated with this configuration. Destroyed if the configuration is deleted.

## Public Methods

### `#published?`
Returns true if the configuration has a `published_at` timestamp.

### `#inherited?`
Returns true if the configuration was cloned from another configuration.

### `#can_inherit_from?(other_config)`
Checks if this configuration can inherit from another (must be same type and not self).
- Parameters: `other_config` (RankingConfiguration)
- Returns: Boolean

### `#clone_for_inheritance`
Returns a new, unsaved configuration cloned from this one, with `inherited_from_id` set and `primary`/`published_at` reset.
- Returns: RankingConfiguration (unsaved)

### `#median_voter_count`
Calculates the median number of voters across all lists in this ranking configuration. Used by weight calculation algorithms to determine voter count penalties.
- Returns: Float/Integer - median voter count, or nil if no data available
- Algorithm: 
  1. Gets all lists associated with ranked lists in this configuration
  2. Extracts non-nil `number_of_voters` values and sorts them
  3. Condenses multiple lists with 1 voter into a single 1 (reduces noise from single-voter lists)
  4. Calculates median for odd/even length arrays
- Used by: Weight calculation services for dynamic penalty calculations

### `#calculate_rankings`
Synchronously calculates rankings for this configuration using weighted_list_rank gem
- Returns: ItemRankings::Calculator::Result with success?, data, errors
- Side effects: Updates ranked_items in database with new ranks and scores
- Algorithm: Uses exponential scoring strategy with configurable parameters

### `#calculate_rankings_async`
Queues background job for asynchronous ranking calculation
- Returns: Sidekiq job ID
- Side effects: Enqueues CalculateRankingsJob for background processing

### `#calculator_service`
Factory method returning appropriate calculator instance based on configuration type
- Returns: Type-specific calculator (e.g., ItemRankings::Music::Albums::Calculator)
- Caching: Instances cached per configuration for performance
- Supported types: Books, Movies, Games, Music::Albums, Music::Songs

## Validations
- `name`: presence, max 255 chars
- `algorithm_version`: presence, integer > 0
- `exponent`: presence, > 0, <= 10
- `bonus_pool_percentage`: presence, 0..100
- `min_list_weight`: presence, integer
- `list_limit`: integer > 0, optional
- `max_list_dates_penalty_age`: integer > 0, optional
- `max_list_dates_penalty_percentage`: integer 1..100, optional
- `primary_mapped_list_cutoff_limit`: integer > 0, optional
- Only one `primary` configuration per media type (STI type)
- Global configs cannot have a user; user configs must have a user
- Inherited configs must be same type as parent

## Scopes
- `global`: Global (site-wide) configurations
- `user_specific`: User-created configurations
- `primary`: Primary configuration for a media type
- `active`: Not archived
- `published`: Has a `published_at` timestamp
- `by_type(type)`: Filter by STI type (e.g., 'Books::RankingConfiguration')

## Constants
_None defined in this model._

## Callbacks
- `before_save :ensure_only_one_primary_per_type`  
  Ensures only one configuration per type is marked as primary.

## Field Explanations
- **type**: STI column. Specifies the media type (e.g., 'Books::RankingConfiguration').
- **name**: Name of the configuration (e.g., "Global Books Ranking").
- **description**: Optional text description.
- **global**: If true, config is site-wide and visible to all users. If false, config is user-specific.
- **primary**: If true, this is the main configuration for its media type. Only one per type.
- **archived**: If true, config is no longer active.
- **published_at**: Timestamp when this config was published/finalized.
- **algorithm_version**: Version of the ranking algorithm used.
- **exponent**: Algorithm parameter (default 3.0). Controls score curve.
- **bonus_pool_percentage**: Algorithm parameter (default 3.0). Percentage of bonus pool for rankings.
- **min_list_weight**: Minimum weight for included lists (default 1).
- **list_limit**: Only count the top X lists for each item (optional).
- **apply_list_dates_penalty**: If true, penalizes items based on recency of list vs. item release date.
- **max_list_dates_penalty_age**: Maximum age (in years) for list date penalty to apply (default varies by type).
- **max_list_dates_penalty_percentage**: Maximum penalty percentage for list date penalty (default varies by type).
- **inherit_penalties**: If true, penalties are cloned when inheriting configs.
- **inherited_from_id**: References the config this one was cloned from (for monthly snapshots/versioning).
- **user_id**: References the user who created the config (null for global configs).
- **primary_mapped_list_id**: For yearly aggregations, the main mapped list (e.g., "Top 100 of 2025").
- **secondary_mapped_list_id**: For yearly aggregations, the secondary mapped list (e.g., "Honorable Mention").
- **primary_mapped_list_cutoff_limit**: Cutoff for the primary mapped list (e.g., 100 for "Top 100").
- **created_at/updated_at**: Standard Rails timestamps.

## Dependencies
- `User` model (for user_id)
- `List` model (for mapped lists)
- STI subclasses for each media type (e.g., Books::RankingConfiguration)
- `RankedItem` and `RankedList` models (for ranking results)
- ItemRankings calculator services for ranking calculations
- CalculateRankingsJob for background processing
- weighted_list_rank gem for ranking algorithm

## Design Notes
- Uses STI for media-specific logic and defaults
- Supports both global and user-specific ranking configurations
- Inheritance system allows for monthly/versioned snapshots
- Penalty system is configurable and inheritable
- Only one primary config per media type enforced at both model and DB level
- Ranked items and lists are destroyed if the configuration is deleted

## Related Models
- `Books::RankingConfiguration`, `Movies::RankingConfiguration`, `Games::RankingConfiguration`, `Music::RankingConfiguration` (STI subclasses)
- `List` (for mapped lists)
- `User` (for user-created configs)
- `RankedItem` (for ranked results)
- `RankedList` (for contributing lists)

## Example Usage
```ruby
# Get the primary books ranking config
Books::RankingConfiguration.primary.first

# Get all ranked items for a config
config.ranked_items.by_rank

# Get all ranked lists for a config
config.ranked_lists

# Clone a config for a new month
new_config = old_config.clone_for_inheritance
new_config.save!

# Get all user-specific configs for a user
RankingConfiguration.user_specific.where(user: user)
``` 