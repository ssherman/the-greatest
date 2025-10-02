# AiChat

## Summary
Represents a conversation session with an AI provider. Stores complete chat history, provider metadata, and response data for all AI interactions across the application.

## Associations
- `belongs_to :parent, polymorphic: true, optional: true` - The entity this chat is related to (e.g., Music::Artist, Books::Book)
- `belongs_to :user, optional: true` - The user who initiated the chat (optional for system-initiated chats)

## Public Methods

### `#add_message(role:, content:, timestamp: Time.current)`
Adds a new message to the chat history
- Parameters: role (String), content (String), timestamp (Time)
- Returns: Updated messages array
- Side effects: Saves the chat record

### `#latest_message`
Returns the most recent message in the chat
- Returns: Hash with role, content, and timestamp keys or nil

### `#message_count`
Returns the total number of messages in the chat
- Returns: Integer

### `#total_tokens_used`
Calculates total tokens used across all API calls
- Returns: Integer sum of all usage.total_tokens

## Validations
- `chat_type` - presence, must be valid enum value
- `model` - presence, string representing the AI model used
- `provider` - presence, must be valid enum value
- `temperature` - presence, numericality between 0 and 2

## Enums

### `chat_type`
- `general: 0` - General purpose conversations
- `ranking: 1` - Ranking and list analysis tasks
- `recommendation: 2` - Recommendation generation tasks
- `analysis: 3` - Data analysis and extraction tasks

### `provider`
- `openai: 0` - OpenAI API (GPT models)
- `anthropic: 1` - Anthropic API (Claude models)
- `gemini: 2` - Google Gemini API
- `local: 3` - Local/self-hosted models

## JSON Fields

### `messages`
Array of message objects with structure:
```json
{
  "role": "user|assistant|system",
  "content": "message content",
  "timestamp": "2024-01-01T10:00:00Z"
}
```

### `raw_responses`
Array of complete provider response objects with timestamps. Each entry contains the full response hash returned by the provider strategy:
```json
{
  "content": "David Bowie was an innovative English singer...",
  "parsed": {
    "description": "Innovative English singer-songwriter and actor",
    "born_on": "1947-01-08",
    "year_died": 2016,
    "country": "GB"
  },
  "id": "chatcmpl-123",
  "model": "gpt-4o",
  "usage": {
    "prompt_tokens": 150,
    "completion_tokens": 85,
    "total_tokens": 235
  },
  "timestamp": "2024-01-01T10:00:00Z"
}
```
This stores the complete provider response for debugging and analysis, not just selected fields.

### `response_schema`
JSON schema used for structured responses (when using json_schema mode):
```json
{
  "type": "object",
  "properties": {
    "field_name": {
      "type": "string",
      "description": "Field description"
    }
  }
}
```

### `parameters`
The exact parameters that will be sent to the AI provider API. This is saved BEFORE making the API call, so we capture the request even if it fails:
```json
{
  "model": "gpt-5-mini",
  "temperature": 1.0,
  "service_tier": "flex",
  "input": "Describe David Bowie as a music artist...",
  "instructions": "You are a music expert...",
  "text": "ArtistDescriptionTask::ResponseSchema",
  "reasoning": {
    "effort": "low"
  }
}
```

**Common parameters:**
- `model` - AI model used for the request
- `temperature` - Temperature setting for response generation
- `input` - The actual user input/messages sent to the API

**Provider-specific parameters:**
- `service_tier` - (OpenAI) Service tier, typically "flex" for cost optimization
- `reasoning` - (OpenAI) Reasoning effort configuration
- `instructions` - (OpenAI) System instructions for Responses API
- `text` - (OpenAI) Schema class name for structured outputs
- `response_format` - Response format specification

These are the raw parameters sent to the provider's API, captured for debugging and observability.

## Scopes
- `by_provider(provider)` - Filter by AI provider
- `by_chat_type(type)` - Filter by chat type
- `recent` - Order by most recent first
- `with_parent` - Only chats that have a parent association

## Constants
- `MAX_TEMPERATURE` - 2.0 (maximum allowed temperature)
- `MIN_TEMPERATURE` - 0.0 (minimum allowed temperature)
- `DEFAULT_TEMPERATURE` - 0.2

## Dependencies
- Polymorphic association with any model that can be a parent
- User model for optional user association
- AI provider services for actual chat completion

## Usage Examples

### Creating a new chat
```ruby
chat = AiChat.create!(
  parent: artist,
  chat_type: :analysis,
  model: "gpt-4",
  provider: :openai,
  temperature: 0.2
)
```

### Adding messages
```ruby
chat.messages ||= []
chat.messages << {
  role: "user",
  content: "Analyze this artist",
  timestamp: Time.current
}
chat.save!
``` 