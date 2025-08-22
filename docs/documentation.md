# The Greatest - Documentation Guide

## Documentation Philosophy
Every class in the application should have a corresponding markdown documentation file. This serves as both human-readable documentation and AI agent context.

## Documentation Structure

### File Organization
Mirror the application structure with `.md` files:
```
docs/
├── models/
│   ├── books/
│   │   ├── book.md
│   │   └── author.md
│   ├── movies/
│   │   ├── movie.md
│   │   └── director.md
│   ├── user.md
│   └── review.md
├── services/
│   ├── books/
│   │   └── import_service.md
│   └── recommendation_service.md
└── controllers/
    ├── books/
    │   └── books_controller.md
    └── application_controller.md
```

## Documentation Template

Each class documentation file should include:

### 1. Class Summary
- One-line description of the class purpose
- Brief explanation of its role in the system
- Which domain it belongs to (if applicable)

### 2. Associations
- List all ActiveRecord associations (including all `has_many`, `belongs_to`, and `has_one` relationships)
- **Always document direct associations to result tables (e.g., `has_many :ranked_items`, `has_many :ranked_lists`)**
- Explain the purpose of each relationship
- Note any polymorphic associations

### 3. Public Methods
- Method name and signature
- Purpose/description
- Parameters with types
- Return value
- Important side effects

### 4. Validations
- List all validations
- Business rules enforced

### 5. Scopes
- Available scopes and their purpose
- Common usage patterns

### 6. Constants
- Any constants defined
- Their purpose and usage

### 7. Callbacks
- Before/after callbacks
- Their purpose and order

### 8. Dependencies
- Required services or modules
- External API dependencies

## Example Structure

```markdown
# Books::Book

## Summary
Represents a book in the system. Core model for the books domain.

## Associations
- `belongs_to :author` - The book's primary author
- `has_many :reviews, as: :reviewable` - Polymorphic association for user reviews
- `has_many :list_items, as: :listable` - Polymorphic association for user lists
- `has_many :ranked_items` - All ranked results for this book (if applicable)

## Public Methods

### `#average_rating`
Calculates the average rating from all reviews
- Returns: Float (1.0-5.0) or nil if no reviews

### `#related_books(limit: 5)`
Finds related books based on genre and author
- Parameters: limit (Integer) - max number of results
- Returns: ActiveRecord::Relation of Books::Book

## Validations
- `title` - presence, uniqueness (case insensitive)
- `slug` - presence, uniqueness, format
- `first_published` - numericality, reasonable range

## Scopes
- `published_between(start_year, end_year)` - Filter by publication date
- `by_genre(genre)` - Filter by genre
- `highly_rated` - Books with average rating >= 4.0

## Constants
- `GENRES` - Array of valid genre strings
- `MAX_TITLE_LENGTH` - 500 characters

## Callbacks
- `before_validation :generate_slug` - Creates URL-friendly slug from title

## Dependencies
- FriendlyId gem for slug generation
- OpenSearch for full-text search indexing
```

## Documentation Standards

### Keep It Current
- Update documentation when code changes
- Documentation is part of the PR review process
- Outdated documentation is worse than no documentation

### Be Concise
- Focus on what the class does, not implementation details
- Document the "why" not just the "what"
- Avoid duplicating code comments

### AI-Friendly Format
- Use consistent markdown structure
- Clear headings and sections
- Descriptive method signatures
- Include types and return values

### Cross-References
- Link to related classes when relevant
- Note which services interact with this model
- Reference any special patterns used
- Document API integration patterns (e.g., search vs browse APIs for external services)

## What NOT to Document
- Private methods
- Implementation details that may change
- Temporary workarounds
- Obvious Rails conventions

## Benefits
- Faster onboarding for new developers
- Better AI agent understanding of codebase
- Living documentation that travels with code
- Encourages thinking about public APIs
- Helps identify overly complex classes