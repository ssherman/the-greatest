# Movies::Movie

## Summary
Represents a movie in the system. Core model for the movies domain with support for ratings, release years, and runtime information.

## Associations
- `has_many :releases, class_name: "Movies::Release", foreign_key: "movie_id", dependent: :destroy` - Different versions/formats of the movie
- `has_many :credits, as: :creditable, class_name: "Movies::Credit", dependent: :destroy` - Polymorphic association for film production credits

## Public Methods

### `#rating`
Returns the movie's rating as a symbol
- Returns: Symbol (g, pg, pg_13, r, nc_17, unrated)

## Validations
- `title` - presence
- `slug` - presence, uniqueness (handled by FriendlyId)
- `release_year` - numericality (integer, greater than 1880, less than or equal to current year + 5), allow_nil
- `runtime_minutes` - numericality (integer, greater than 0), allow_nil

## Scopes
No custom scopes defined yet. Future scopes may include:
- `by_rating(rating)` - Filter by rating
- `released_between(start_year, end_year)` - Filter by release year range
- `longer_than(minutes)` - Filter by minimum runtime

## Constants
No constants defined.

## Callbacks
- FriendlyId callbacks for automatic slug generation from title

## Dependencies
- FriendlyId gem for slug generation
- ActiveRecord for database operations

## Enums
- `rating` - Movie rating system (g, pg, pg_13, r, nc_17, unrated) 