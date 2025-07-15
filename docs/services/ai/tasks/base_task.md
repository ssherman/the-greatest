# Services::Ai::Tasks::BaseTask

## Summary
Abstract base class for AI task implementations. Provides common functionality for structured AI interactions including chat creation, message handling, and response processing. Uses template method pattern for consistent task execution.

## Public Methods

### `#initialize(parent:, provider: nil, model: nil)`
Creates a new task instance
- Parameters:
  - `parent` (ActiveRecord::Base) - The entity this task operates on
  - `provider` (Symbol, optional) - Override provider selection
  - `model` (String, optional) - Override model selection
- Side effects: Validates parent, creates provider instance, sets model

### `#call`
Executes the complete AI task workflow
- Returns: Services::Ai::Result with success/failure, data, and ai_chat
- Side effects: Creates AiChat, sends messages, processes response, updates parent
- Error handling: Catches all StandardError and returns failure result

## Protected Methods (Abstract)

### `#user_prompt`
**Must be implemented by subclasses** - Generates the user prompt for the AI
- Returns: String with the prompt text
- Raises: NotImplementedError if not implemented

## Protected Methods (Overridable)

### `#task_provider`
Override to specify preferred provider for this task
- Returns: Symbol (e.g., `:openai`, `:anthropic`) or nil for default
- Default: nil (uses default provider)

### `#task_model`
Override to specify preferred model for this task
- Returns: String (e.g., "gpt-4", "claude-3-sonnet") or nil for provider default
- Default: nil (uses provider default)

### `#chat_type`
Override to specify chat type for this task
- Returns: Symbol matching AiChat enum values
- Default: `:analysis`

### `#system_message`
Override to provide system prompt for the AI
- Returns: String with system instructions or nil for no system message
- Default: nil

### `#response_format`
Override to specify response format requirements
- Returns: Hash with format options (e.g., `{ type: "json_object" }`) or nil
- Default: nil

### `#response_schema`
Override to specify structured response schema
- Returns: RubyLLM::Schema class or nil
- Default: nil

### `#temperature`
Override to specify response randomness
- Returns: Float between 0.0 and 2.0
- Default: 0.2

### `#process_and_persist(provider_response)`
Override to handle the AI response and update the parent
- Parameters: provider_response (Hash) - Response from AI provider
- Returns: Services::Ai::Result
- Default: Returns success result with raw response data

## Private Methods

### `#create_chat!`
Creates AiChat record with task configuration
- Returns: AiChat instance
- Side effects: Saves to database

### `#add_user_message(content)`
Adds user message to the chat
- Parameters: content (String) - Message content
- Side effects: Updates chat messages and saves

### `#update_chat_with_response(provider_response)`
Adds AI response to chat history
- Parameters: provider_response (Hash) - Provider response data
- Side effects: Updates chat messages and raw_responses, saves

### `#validate_parent!`
Validates that parent is present
- Raises: ArgumentError if parent is nil

### `#create_result(success:, data:, error:, ai_chat:)`
Creates standardized result object
- Parameters: success (Boolean), data (Hash), error (String), ai_chat (AiChat)
- Returns: Services::Ai::Result

## Usage Pattern
```ruby
class MyTask < Services::Ai::Tasks::BaseTask
  private

  def task_provider = :openai
  def task_model = "gpt-4"
  def chat_type = :analysis

  def system_message
    "You are an expert at analyzing data."
  end

  def user_prompt
    "Please analyze #{parent.name}"
  end

  def response_format
    { type: "json_object" }
  end

  def response_schema
    MyResponseSchema
  end

  def process_and_persist(provider_response)
    data = provider_response[:parsed]
    parent.update!(analysis: data[:analysis])
    Services::Ai::Result.new(success: true, data: data, ai_chat: chat)
  end
end
```

## Subclasses
- `Services::Ai::Tasks::ArtistDetailsTask` - Artist information extraction
- Additional task classes for other domains (books, movies, etc.)

## Dependencies
- Services::Ai::Capable module
- Services::Ai::ProviderRegistry for provider management
- Services::Ai::Result for standardized responses
- AiChat model for conversation storage
- RubyLLM::Schema for structured responses

## Error Handling
- Parent validation errors raise ArgumentError
- Provider errors caught and returned as failure results
- Database errors caught and returned as failure results
- All errors logged with context

## Design Notes
This class implements the Template Method pattern to ensure consistent task execution while allowing customization at key points. The workflow is: create chat → add system message → add user message → call provider → process response → return result. Each step can be customized by subclasses through method overrides. 