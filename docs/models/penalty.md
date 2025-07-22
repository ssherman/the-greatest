# Penalty

## Summary
Represents a penalty definition that can be applied to lists in ranking configurations. Uses Single Table Inheritance (STI) to support both cross-media penalties (`Global::Penalty`) and media-specific penalties (`Books::Penalty`, `Music::Penalty`, etc.). Used to reduce the weight of lists based on various criteria.

## Associations
- `belongs_to :user, optional: true` - The user who created the penalty (null for system-wide penalties)
- `has_many :penalty_applications, dependent: :destroy` - All applications of this penalty to ranking configurations
- `has_many :ranking_configurations, through: :penalty_applications` - Ranking configurations this penalty is applied to
- `has_many :list_penalties, dependent: :destroy` - All associations of this penalty to lists
- `has_many :lists, through: :list_penalties` - Lists this penalty is applied to

## Public Methods

### `#global?`
Returns true if the penalty is system-wide (available to all users).
- Returns: Boolean
- Implementation: `user_id.nil?`

### `#user_specific?`
Returns true if the penalty is user-specific (belongs to a particular user).
- Returns: Boolean  
- Implementation: `user_id.present?`

### `#dynamic?`
Returns true if the penalty has a dynamic_type (requires runtime calculation).
- Returns: Boolean
- Implementation: `dynamic_type.present?`

### `#static?`
Returns true if the penalty is static (fixed value, no dynamic calculation).
- Returns: Boolean
- Implementation: `dynamic_type.nil?`



**Note:** Penalty calculation logic has been moved to service objects (`Rankings::WeightCalculatorV1`) following "Skinny Models, Fat Services" principles. The model only provides data definitions and type checking.

## Validations
- `name` - presence required
- `type` - presence required (for STI)
- `dynamic_type` - optional enum, when present indicates dynamic calculation needed

## Scopes
- `dynamic` - Penalties with dynamic_type present (calculated at runtime)
- `static` - Penalties without dynamic_type (fixed values)
- `by_dynamic_type(dynamic_type)` - Filter by specific dynamic penalty type

## Constants
- Enum: `dynamic_type` (number_of_voters, percentage_western, voter_names_unknown, voter_count_unknown, category_specific, location_specific)

## Callbacks
None defined.

## Dependencies
- User model (for user-specific penalties)
- PenaltyApplication model
- ListPenalty model
- STI subclasses for penalty types

## STI Subclasses

### Global::Penalty
Cross-media penalties that can be applied to any media type.
- Can be system-wide (`user_id: nil`) or user-specific (`user_id: present`)

### Books::Penalty
Book-specific penalties that only apply to book lists and configurations.
- Can be system-wide (`user_id: nil`) or user-specific (`user_id: present`)

### Movies::Penalty
Movie-specific penalties that only apply to movie lists and configurations.

### Games::Penalty  
Game-specific penalties that only apply to game lists and configurations.

### Music::Penalty
Music-specific penalties that only apply to music lists and configurations.

## Design Decisions

### STI vs Enum/Boolean Fields
Using pure STI approach for:
- **Cleaner semantics**: `Global::Penalty` clearly indicates cross-media
- **Zero redundancy**: Type information is stored once in `type` column
- **Better queries**: `Global::Penalty.all` vs complex enum filtering
- **Extensibility**: Easy to add new penalty types without schema changes

### Global vs User-Specific
- **System-wide penalties** (`user_id: nil`): Available to all users, managed by administrators
- **User-specific penalties** (`user_id: present`): Private to the creating user
- Both modes supported for all penalty types (Global and media-specific)

## Related Services
- `Rankings::WeightCalculatorV1` - Handles all penalty calculation logic using Penalty definitions
- `Rankings::BulkWeightCalculator` - Processes penalty calculations for multiple rankings

## Usage Examples
```ruby
# Create system-wide cross-media penalty
global_penalty = Global::Penalty.create!(name: "Limited Time Coverage")
global_penalty.global?          # => true

# Create user-specific music penalty
user_penalty = Music::Penalty.create!(
  name: "Personal Music Bias", 
  user: current_user
)
user_penalty.user_specific?     # => true

# Query by type
Global::Penalty.all             # All cross-media penalties
Music::Penalty.all              # All music-specific penalties
Penalty.dynamic                 # All dynamic penalties across types
``` 