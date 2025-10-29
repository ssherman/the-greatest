# The Greatest - Developer Core Values

## 1. AI-First Development
- **Clear naming conventions**: Use descriptive, semantic names for all variables, methods, and classes
- **Self-documenting code**: Write code that explains its purpose without extensive comments
- **Structured data**: Prefer structured formats (JSON, structured logs) over unstructured text
- **API design**: RESTful endpoints with clear, predictable patterns
- **Documentation**: Every module includes purpose, inputs, outputs, and examples

## 2. Domain-Driven Design with Namespacing
- **Media-specific modules**: All book, movie, game, and music-specific code must be namespaced
  ```
  Books::ListAggregator, Movies::ReviewService, Games::MetadataParser, Music::AlbumImporter
  ```
- **Shared functionality**: Global namespace for cross-media features
  ```
  RecommendationEngine, UserListService, SearchService, RankingCalculator
  ```
- **Clear boundaries**: Never mix media-specific logic in global classes
- **Module structure**:
  ```
  app/models/
    books/
      book.rb
      author.rb
    movies/
      movie.rb
      director.rb
    # Shared models in root
    user.rb
    list.rb
    review.rb
  ```

## 3. Database Design Principles
- **Human-readable URLs**: FriendlyId for all user-facing resources
- **Polymorphic relationships**: Extensive use for shared functionality
  ```ruby
  # Reviews can belong to any media type
  belongs_to :reviewable, polymorphic: true
  
  # User lists can contain any media type
  belongs_to :listable, polymorphic: true
  ```
- **Consistent naming**: Use `_able` suffix for polymorphic associations
- **Polymorphic fixtures**: Use Rails fixture syntax with target type specification
  ```yaml
  # ✅ Correct polymorphic fixture syntax
  basic_item:
    list: basic_list
    listable: dark_side_of_the_moon (Music::Album)
    position: 1
  
  # ❌ Incorrect - will cause errors
  basic_item:
    list: basic_list
    listable: dark_side_of_the_moon
    listable_type: Music::Album
    position: 1
  ```
  - Always use `association_name: fixture_name (ClassName)` format
  - Never manually set `_type` fields in fixtures
  - Rails automatically handles the polymorphic type mapping

## 4. Simplicity Over Complexity
- **YAGNI principle**: Build only what's required now
- **Rails defaults**: Use built-in Rails tools before reaching for gems
- **Clear abstractions**: Avoid premature optimization
- **Readable code**: Optimize for human and AI comprehension

## 5. Skinny Models, Fat Services
- **Model responsibilities**: Models handle ONLY validations, associations, and scopes
- **Service objects**: Extract all business logic into services
- **Service organization**: Namespace services by domain
  ```
  app/services/
    books/
      import_service.rb
      metadata_enrichment_service.rb
    # Shared services
    recommendation_service.rb
  ```

## 6. Multi-Domain Architecture
- **Separate domains**: thegreatestbooks.org, thegreatestmusic.org, etc.
- **Host detection**: Early request handling to determine current domain
- **Conditional loading**: Load only necessary assets and views per domain
- **Shared components**: ViewComponents with domain-specific styling
- **Build process**: Rollup with separate bundles per domain

## 7. Convention Over Configuration
- **Rails Way**: Follow Rails conventions - use what Rails provides
- **RESTful routes**: Maintain predictable URL patterns
- **Testing approach**: Minitest with fixtures (see testing-guide.md)
- **Default tools**: Prefer Rails built-ins over external gems
- **Always use generators**: ALWAYS use Rails generators to create new files - they automatically create test files and follow conventions
  ```bash
  # ✅ Correct - Use generators
  rails generate controller Music::Searches index
  rails generate model Music::Artist name:string slug:string:uniq
  rails generate stimulus music/player
  rails generate component Music::Artists::Card artist
  rails generate avo:resource Music::Artist

  # ❌ Incorrect - Don't manually create files
  touch app/controllers/music/searches_controller.rb
  touch app/models/music/artist.rb
  ```
  **Why?** Generators automatically:
  - Create test files in the correct location with proper namespacing
  - Follow Rails naming conventions and file structure
  - Set up boilerplate code correctly
  - Prevent common mistakes and oversights
-   **Rails 8 enum syntax**: Always use the new format with colon prefix
  ```ruby
  # ✅ Correct Rails 8 syntax
  enum :dynamic_type, { number_of_voters: 0, percentage_western: 1, voter_names_unknown: 2 }

  # ❌ Old Rails syntax (will cause errors)
  enum dynamic_type: { number_of_voters: 0, percentage_western: 1, voter_names_unknown: 2 }
  ```

## 8. Progressive Enhancement
- **Server-first rendering**: Full functionality without JavaScript
- **Turbo Frames**: Enhanced navigation without full page reloads
- **Stimulus controllers**: Minimal JavaScript for interactivity
- **Performance baseline**: Optimize for slow connections

## 9. Data Integrity
- **Database constraints**: Enforce rules at the database level
- **Validations**: Comprehensive model validations
- **Transactions**: Wrap multi-step operations

## 10. Search and Discovery
- **OpenSearch integration**: Full-text search across all media types
- **Faceted search**: Media-specific filters stored as JSONB
- **Background indexing**: Sidekiq jobs for search updates
- **Unified search**: Cross-media search when appropriate

## 11. AI Integration Standards
- **Service pattern**: All AI interactions through service objects
- **Structured prompts**: Consistent prompt templates
- **Response parsing**: Parse AI responses into structured data
- **Fallback handling**: Graceful degradation when AI services fail

## 12. Caching Strategy
- **Russian doll caching**: Nested fragment caching
- **Redis integration**: Centralized cache store
- **Domain-aware keys**: Include domain context in cache keys
- **Background refresh**: Sidekiq jobs for cache warming

## 13. Security by Design
- **Authentication**: Firebase Auth with proper session handling
- **Authorization**: Simple role-based access control
- **Input sanitization**: Strong parameters everywhere
- **Secure defaults**: Start with restrictive permissions

## 14. Background Processing
- **Default queue**: Always use the default queue unless specifically needed
  ```ruby
  class Books::ImportJob
    include Sidekiq::Job
    # No queue_as needed - uses default queue
  end
  ```
- **Special queues**: ONLY use named queues for serial jobs that interact with rate-limited external APIs (AI services, etc.)
  ```ruby
  class Ai::DescriptionJob
    include Sidekiq::Job
    queue_as :ai_serial  # Special queue for rate-limited AI API calls
  end
  ```
- **Idempotent jobs**: All jobs must be safely retryable
- **Job monitoring**: Track performance and failures

## 15. Service Object Pattern
- **Result pattern**: Consistent success/failure responses
  ```ruby
  class ApplicationService
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)
    
    def self.call(...)
      new(...).call
    end
  end
  ```
- **Dependency injection**: Accept dependencies through constructor
- **Single responsibility**: One clear purpose per service

## 16. Performance Guidelines
- **N+1 prevention**: Use `includes` and `preload`
- **Database indexes**: Index all foreign keys and search fields
- **Query optimization**: EXPLAIN ANALYZE on slow queries
- **Asset optimization**: Minimize and compress all assets

## 17. Monitoring and Observability
- **Structured logging**: Consistent log format
- **Error tracking**: Comprehensive error reporting
- **Performance monitoring**: Track response times per domain
- **Business metrics**: Domain-specific KPIs

## Related Documentation
- **Testing**: See `testing-guide.md` for comprehensive testing guidelines
- **Project Overview**: See `summary.md` for project context