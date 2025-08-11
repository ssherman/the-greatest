# Movies::Category

## Summary
Movies-specific category model for categorizing films and cinema content. Inherits from base Category model with movie-specific associations and scopes.

## Associations
- `has_many :movies, through: :category_items, source: :item, source_type: 'Movies::Movie'` - Movies in this category

## Public Methods
Inherits all methods from base Category model.

## Validations
Inherits all validations from base Category model.

## Scopes
- `by_movie_ids(movie_ids)` - Find categories containing specific movies

## Constants
Inherits all constants from base Category model.

## Callbacks
Inherits all callbacks from base Category model.

## Dependencies
- Base Category model
- Movies::Movie model
- Polymorphic CategoryItem associations

## Usage Examples
```ruby
# Create a movie genre category
horror = Movies::Category.create!(name: "Horror", category_type: "genre")

# Add movies to the category
horror.movies << the_shining
horror.movies << halloween

# Find all horror movies
horror.movies

# Find categories by movie
Movies::Category.by_movie_ids([movie1.id, movie2.id])
```
