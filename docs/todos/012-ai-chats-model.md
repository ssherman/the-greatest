# 012 - AI Chats Model Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-07-11
- **Started**: 2025-07-12
- **Completed**: 2025-07-12
- **Developer**: Assistant

## Overview
Implement a comprehensive AI chat tracking system that records all AI interactions across multiple providers (OpenAI, Google AI, Claude, etc.). This system will track AI requests/responses for data entry, item parsing, summaries, confirmations, and future user-facing AI features.

## Context
The application heavily uses AI for various tasks:
- Parsing items from lists
- Generating item summaries
- Creating author/artist/actor/people descriptions
- Confirming item matches from search results
- Future user-facing AI chat features

We need a robust system to:
- Track every AI interaction with full request/response history
- Support multiple AI providers (not just OpenAI)
- Associate AI chats with specific model instances
- Provide an easy interface for making AI requests
- Support different chat types (system vs user)

This replaces and improves upon the old ai_chats system from The Greatest Books.

## Requirements
- [x] Create AiChat model with polymorphic associations
- [x] Support multiple AI providers (OpenAI, Anthropic, Gemini, Local)
- [x] Store complete message history in JSONB
- [x] Support provider-specific features (json_mode, response_schema)
- [x] Add chat_type enum (general, ranking, recommendation, analysis)
- [x] Associate chats with model instances (optional)
- [x] Track temperature, model, and other parameters
- [x] Add comprehensive test coverage
- [x] Create fixtures for common AI chat scenarios
- [ ] Create service layer for easy AI interactions (future task)

## Technical Approach

### Database Design
```sql
CREATE TABLE ai_chats (
  id bigint PRIMARY KEY,
  chat_type integer DEFAULT 0 NOT NULL, -- enum: 0=system, 1=user
  model varchar NOT NULL, -- e.g., 'gpt-4', 'claude-3', 'gemini-pro'
  provider integer DEFAULT 0 NOT NULL, -- enum: 0=openai, 1=anthropic, 2=google, etc.
  temperature decimal(3,2) DEFAULT 0.2 NOT NULL,
  json_mode boolean DEFAULT false NOT NULL,
  response_schema jsonb, -- JSON schema for structured responses
  messages jsonb, -- Array of all messages in conversation (nullable)
  raw_responses jsonb, -- Array of raw provider responses
  parent_type varchar, -- polymorphic association
  parent_id bigint, -- polymorphic association
  user_id bigint, -- optional user association
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);
```

### Model Structure

#### AiChat Model
- Polymorphic associations for flexible parent relationships
- Enum for chat_type (system vs user)
- JSONB fields for messages and responses
- Provider-specific feature support
- Comprehensive validation and scoping

#### Service Layer (Future Implementation)
- `AiChatService` - Main service for creating and managing chats
- `OpenAiService` - OpenAI-specific implementation
- `AnthropicService` - Claude-specific implementation
- `GoogleAiService` - Google AI-specific implementation
- Provider-agnostic interface for easy switching

### Integration Points
- Polymorphic associations with any model (books, movies, lists, etc.)
- User association for user-facing chats
- Service layer integration with existing AI-powered features

## Dependencies
- User model for user associations
- Various content models for polymorphic associations
- AI provider gems/libraries
- JSONB support in PostgreSQL

## Acceptance Criteria
- [x] AI chats can be created for any model instance
- [x] Complete message history is preserved in JSONB
- [x] Multiple AI providers are supported
- [x] Provider-specific features work correctly
- [x] Chat types are distinguished (general, ranking, recommendation, analysis)
- [x] Temperature and other parameters are tracked
- [ ] Service layer provides easy AI interaction interface (future task)
- [x] All models have comprehensive test coverage
- [x] Common AI chat scenarios are available as fixtures

## Design Decisions

### Why Polymorphic Associations?
- AI chats can be associated with any model (books, movies, lists, etc.)
- Flexible and extensible for future content types
- Maintains referential integrity

### JSONB for Messages
- Stores complete conversation history
- Flexible structure for different provider formats
- Efficient querying and indexing capabilities

### Provider-Specific Features
- `json_mode` and `response_schema` are OpenAI-specific
- Other providers may have different features
- Extensible design for future providers

### Service Layer Pattern
- Encapsulates provider-specific logic
- Easy to switch between providers
- Consistent interface for AI interactions

### Chat Type Enum
- Distinguishes between system-generated and user-initiated chats
- Enables future user-facing AI features
- Helps with analytics and filtering

---

## Implementation Notes

### Approach Taken
- Created AiChat model with polymorphic parent association and optional user association
- Used Rails 8 enum syntax with colon prefix for chat_type and provider enums
- Implemented comprehensive validations for required fields (model, temperature, etc.)
- Added has_many :ai_chats relationships to base models (List, Movie, Album, Artist, Song)
- Created Avo admin resource with proper enum display
- Built comprehensive test suite with fixtures

### Key Files Changed
- `db/migrate/20250712194724_create_ai_chats.rb` - Database migration
- `app/models/ai_chat.rb` - Main model with associations, enums, and validations
- `app/avo/resources/ai_chat.rb` - Admin interface configuration
- `test/models/ai_chat_test.rb` - Comprehensive test suite
- `test/fixtures/ai_chats.yml` - Test fixtures with polymorphic associations
- `app/models/list.rb` - Added has_many :ai_chats relationship
- `app/models/movies/movie.rb` - Added has_many :ai_chats relationship
- `app/models/music/album.rb` - Added has_many :ai_chats relationship
- `app/models/music/artist.rb` - Added has_many :ai_chats relationship
- `app/models/music/song.rb` - Added has_many :ai_chats relationship

### Challenges Encountered
- **Rails 8 enum syntax**: Initially used old syntax, corrected to use colon prefix
- **Boolean presence validation**: Attempted to validate json_mode presence, but Rails treats false as blank for presence validation
- **Polymorphic fixtures**: Used correct Rails syntax `association_name: fixture_name (ClassName)` format
- **Required fields**: Initially missed required fields from migration in model validations

### Deviations from Plan
- **Chat types**: Changed from system/user to general/ranking/recommendation/analysis for more specific use cases
- **Providers**: Added "local" provider option for future local AI models
- **Simplified model**: Removed unnecessary methods and scopes to keep model focused on basics
- **Boolean validation**: Removed presence validation for json_mode since database enforces non-null

### Code Examples
```ruby
# Creating an AI chat for a movie
movie.ai_chats.create!(
  chat_type: :analysis,
  provider: :openai,
  model: "gpt-4",
  temperature: 0.2,
  json_mode: false,
  messages: [{ role: "user", content: "Analyze this movie", timestamp: Time.current }]
)

# Polymorphic association in fixtures
ranking_chat:
  chat_type: ranking
  model: "claude-3"
  provider: anthropic
  temperature: 0.1
  json_mode: true
  messages: [{ role: "system", content: "Rank these items", timestamp: "2024-01-01T11:00:00Z" }]
  parent: books_list (Books::List)
```

### Testing Approach
- Comprehensive model tests covering all validations
- Enum value testing for chat_type and provider
- Association testing for polymorphic parent and user
- Fixture-based testing with realistic data scenarios
- Validation error message testing

### Performance Considerations
- JSONB fields for messages and responses allow efficient querying
- Polymorphic associations maintain referential integrity
- Database indexes on foreign keys and polymorphic fields

### Future Improvements
- Service layer implementation for easy AI interactions
- Background job processing for AI requests
- Caching layer for AI responses
- Analytics tracking for AI usage patterns
- User-facing AI chat interface

### Lessons Learned
- **Rails 8 enum syntax**: Always use colon prefix format
- **Boolean validations**: Don't use presence validation for booleans
- **Polymorphic fixtures**: Use correct Rails syntax with target type specification
- **Keep models simple**: Focus on associations, enums, and validations only
- **Database constraints**: Let database handle non-null constraints rather than presence validations

### Related PRs
- Initial implementation of AiChat model and relationships

### Documentation Updated
- [x] Updated dev-core-values.md with polymorphic fixture best practices
- [x] Updated dev-core-values.md with Rails 8 enum syntax requirements