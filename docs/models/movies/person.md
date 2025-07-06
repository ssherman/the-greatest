# Movies::Person

## Summary
Represents an individual involved in film production (director, actor, crew, etc.) in the movies domain.

## Associations
- `has_many :credits, class_name: "Movies::Credit", foreign_key: "person_id", dependent: :destroy` - All credits for this person across movies and releases
- `has_many :memberships, class_name: "Movies::Membership", foreign_key: "person_id", dependent: :destroy` - Cast/crew assignments to specific releases

## Public Methods

### `#gender`
Returns the person's gender as a symbol.
- Returns: Symbol (male, female, non_binary, other)

## Validations
- `name` - presence
- `slug` - presence, uniqueness (handled by FriendlyId)
- `country` - length is 2 (ISO-3166 alpha-2), allow_nil
- `gender` - inclusion in valid genders, allow_nil
- Custom validation: `died_on` must be after `born_on` if both are present

## Scopes
No custom scopes defined yet. Future scopes may include:
- `alive` - People without a `died_on` date
- `deceased` - People with a `died_on` date
- `by_country(country_code)` - Filter by country

## Constants
None defined.

## Callbacks
- FriendlyId callbacks for automatic slug generation from name

## Dependencies
- FriendlyId gem for slug generation
- ActiveRecord for database operations

## Enums
- `gender` - { male: 0, female: 1, non_binary: 2, other: 3 } 