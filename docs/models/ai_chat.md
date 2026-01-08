# AiChat

## Summary
Stores AI conversation history and metadata for interactions with AI providers. Supports polymorphic association to various parent entities (artists, albums, songs, lists) and optional user association.

## Associations
- `belongs_to :parent, polymorphic: true, optional: true` - The entity this chat is about (e.g., Music::Artist, Music::Album, List)
- `belongs_to :user, optional: true` - The user who initiated the chat (if user-facing)

### Polymorphic Parent Types
The `parent` association can reference:
- `Music::Artist`, `Music::Album`, `Music::Song` - Direct music entities
- `List` (STI base class) - For list-related chats, the actual STI type is in `lists.type`

**Important**: Rails stores the base class name (`List`) in `parent_type` for STI models. Use `with_list_parent_types` scope to filter by specific List STI subclasses.

## Attributes

### Core Fields
- `model` (string, required) - The AI model identifier (e.g., "gpt-4", "claude-3")
- `temperature` (decimal, required) - Model temperature setting (0.0-2.0, default: 0.2)
- `json_mode` (boolean, default: false) - Whether to request JSON-formatted responses

### Enums
- `chat_type` - Purpose of the chat:
  - `general` (0, default) - General purpose chat
  - `ranking` (1) - Ranking-related operations
  - `recommendation` (2) - Recommendation generation
  - `analysis` (3) - Content analysis

- `provider` - AI provider:
  - `openai` (0, default)
  - `anthropic` (1)
  - `gemini` (2)
  - `local` (3)

### JSONB Fields
- `messages` - Array of conversation messages with structure:
  ```json
  [{"role": "user|system|assistant", "content": "...", "timestamp": "ISO8601"}]
  ```
- `parameters` - Additional provider-specific parameters
- `raw_responses` - Raw API responses for debugging/auditing
- `response_schema` - JSON schema for structured responses (when `json_mode: true`)

## Validations
- `chat_type` - presence required
- `model` - presence required
- `provider` - presence required
- `temperature` - presence required, must be between 0 and 2

## Scopes

### `with_list_parent_types(sti_types)`
Filters AiChats by List STI subclass types. Required because Rails stores the base class name (`List`) in polymorphic `parent_type`, not the STI subclass.

**Parameters:**
- `sti_types` (Array<String>) - STI type names (e.g., `['Music::Albums::List', 'Music::Songs::List']`)

**Returns:** ActiveRecord::Relation of AiChats where:
- `parent_type = 'List'` AND
- `lists.type IN (sti_types)`

**Edge cases:**
- Empty/nil array returns empty relation (`none`)
- Invalid type strings return empty relation (no error)

**Usage:**
```ruby
# Get chats for music album lists
AiChat.with_list_parent_types(['Music::Albums::List'])

# Get chats for all music lists
AiChat.with_list_parent_types(['Music::Albums::List', 'Music::Songs::List'])

# Chainable with other scopes
AiChat.with_list_parent_types(['Music::Albums::List']).includes(:parent).where(provider: :openai)
```

**Note:** This scope uses an INNER JOIN and cannot be combined with `.or()` on non-JOIN relations. Use ID-based filtering if combining with other conditions.

## Indexes
- `index_ai_chats_on_parent` - Composite index on `(parent_type, parent_id)`
- `index_ai_chats_on_user_id` - Index on `user_id`

## Dependencies
- Used by AI task services for storing conversation state
- Referenced by admin controllers for viewing chat history

## Related Documentation
- `docs/controllers/admin/music/ai_chats_controller.md` - Admin interface for music-related chats
