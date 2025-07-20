# Penalty

## Summary
Represents a penalty definition that can be applied to lists in ranking configurations. Supports global/user-specific, static/dynamic, and media-specific/cross-media penalties. Used to reduce the weight of lists based on various criteria.

## Associations
- `belongs_to :user, optional: true` - The user who created the penalty (null for global penalties)
- `has_many :penalty_applications, dependent: :destroy` - All applications of this penalty to ranking configurations
- `has_many :ranking_configurations, through: :penalty_applications` - Ranking configurations this penalty is applied to
- `has_many :list_penalties, dependent: :destroy` - All associations of this penalty to lists
- `has_many :lists, through: :list_penalties` - Lists this penalty is applied to

## Public Methods

### `#global?`
Returns true if the penalty is global (site-wide)
- Returns: Boolean

### `#user_specific?`
Returns true if the penalty is user-specific
- Returns: Boolean

### `#dynamic?`
Returns true if the penalty has a dynamic_type (calls custom calculation logic)
- Returns: Boolean
- Implementation: `dynamic_type.present?`

### `#static?`
Returns true if the penalty is static (fixed value, no dynamic calculation)
- Returns: Boolean
- Implementation: `dynamic_type.blank?`

### `#cross_media?`
Returns true if the penalty applies to all media types
- Returns: Boolean

### `#media_specific?`
Returns true if the penalty is media-specific
- Returns: Boolean

### `#calculate_penalty_value(list, ranking_configuration)`
Returns the penalty value for a given list and ranking configuration. Overridden by dynamic subclasses.
- Parameters: list (List), ranking_configuration (RankingConfiguration)
- Returns: Integer (penalty percentage)

## Validations
- `name` - presence required
- `type` - presence required (for STI)
- `global` - must be true or false
- `dynamic` - must be true or false
- `media_type` - presence required, must match STI type if media-specific
- Custom: user must be present for user-specific penalties
- Custom: STI type and media_type must be consistent

## Scopes
- `global` - Global penalties
- `user_specific` - User-specific penalties
- `dynamic` - Penalties with dynamic_type present (calculated at runtime)
- `static` - Penalties without dynamic_type (fixed values)
- `by_media_type(media_type)` - Filter by media type
- `by_dynamic_type(dynamic_type)` - Filter by specific dynamic penalty type
- `cross_media` - Cross-media penalties

## Constants
- Enum: `media_type` (cross_media, books, movies, games, music)
- Enum: `dynamic_type` (number_of_voters, percentage_western, voter_names_unknown, voter_count_unknown, category_specific, location_specific)

## Callbacks
_None defined._

## Dependencies
- User model (for user-specific penalties)
- PenaltyApplication model
- ListPenalty model
- STI subclasses for media-specific penalties 