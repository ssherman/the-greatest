# Movies::Release

## Summary
Represents a specific version/format of a movie (theatrical, director's cut, extended, etc.) in the movies domain.

## Associations
- `belongs_to :movie, class_name: "Movies::Movie", foreign_key: "movie_id"` - The parent movie
- `has_many :credits, as: :creditable, class_name: "Movies::Credit", dependent: :destroy` - Polymorphic association for release-specific credits

## Public Methods

### `#release_format`
Returns the release format as a symbol.
- Returns: Symbol (theatrical, dvd, blu_ray, digital, vhs, 4k_blu_ray)

## Validations
- `movie_id` - presence
- `release_format` - presence
- `is_primary` - inclusion in [true, false]
- `release_name` - uniqueness scoped to movie and format, allow_nil
- `runtime_minutes` - numericality (integer, greater than 0), allow_nil
- Custom validation: `release_date` cannot be in the future

## Scopes
- `primary` - Releases marked as primary (canonical version)
- `by_release_format(fmt)` - Filter by release format
- `recent` - Order by release date descending

## Constants
None defined.

## Callbacks
None defined.

## Dependencies
- ActiveRecord for database operations

## Enums
- `release_format` - { theatrical: 0, dvd: 1, blu_ray: 2, digital: 3, vhs: 4, 4k_blu_ray: 5 } 