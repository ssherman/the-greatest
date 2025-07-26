# Services::Ai::Providers::OpenaiStrategy

## Summary
OpenAI API implementation of the AI provider strategy. Handles chat completions using OpenAI's GPT models with support for JSON mode, JSON schema, and function calling.

## Public Methods

### `#capabilities`
Returns OpenAI-specific capabilities
- Returns: `[:json_mode, :json_schema, :function_calls]`

### `#default_model`
Returns the default GPT model
- Returns: `"gpt-4"`

### `#provider_key`
Returns the provider identifier for AiChat enum
- Returns: `:openai`

## Protected Methods

### `#client`
Returns memoized OpenAI client instance
- Returns: OpenAI::Client instance
- Memoized: Yes, creates client once and reuses

### `#make_api_call(parameters)`
Makes chat completion API call to OpenAI
- Parameters: parameters (Hash) - API parameters including model, messages, temperature, etc.
- Returns: OpenAI chat completion response object
- API: Uses `client.chat.completions.create(parameters)`

### `#format_response(response, schema)`
Formats OpenAI response into standard structure
- Parameters: 
  - `response` - OpenAI chat completion response
  - `schema` (Class, optional) - RubyLLM::Schema for parsing
- Returns: Hash with `:content`, `:parsed`, `:id`, `:model`, `:usage` keys
- Processing: Extracts first choice, parses JSON content, validates against schema

### `#build_parameters(model:, messages:, temperature:, response_format:, schema:)`
Builds OpenAI-specific API parameters
- Parameters: 
  - `model` (String) - GPT model identifier
  - `messages` (Array) - Chat message history
  - `temperature` (Float) - Response randomness (0-2)
  - `response_format` (Hash, optional) - Response format options
  - `schema` (Class, optional) - RubyLLM::Schema class
- Returns: Hash with OpenAI API parameters
- OpenAI-specific: Adds `response_format` with JSON schema or JSON mode

## Response Format Handling

### JSON Schema Mode
When `schema` is provided and inherits from `RubyLLM::Schema`:
```ruby
parameters[:response_format] = {
  type: "json_schema",
  json_schema: JSON.parse(schema.new.to_json)
}
```

### JSON Mode
When `response_format` is provided without schema:
```ruby
parameters[:response_format] = response_format
# e.g., { type: "json_object" }
```

## Usage Examples

### Basic chat completion
```ruby
strategy = Services::Ai::Providers::OpenaiStrategy.new
response = strategy.send_message!(
  ai_chat: chat,
  content: "Hello, world!",
  response_format: nil,
  schema: nil
)
```

### With JSON schema
```ruby
class MySchema < RubyLLM::Schema
  string :name, required: true
  integer :age, required: false
end

response = strategy.send_message!(
  ai_chat: chat,
  content: "Extract person details",
  response_format: nil,
  schema: MySchema
)
```

### With JSON mode
```ruby
response = strategy.send_message!(
  ai_chat: chat,
  content: "Return JSON",
  response_format: { type: "json_object" },
  schema: nil
)
```

## Error Handling
- Network errors: Propagated from OpenAI::Client
- JSON parsing errors: Handled by parent class `parse_response`
- API errors: Propagated with OpenAI error details
- Invalid parameters: Validated by OpenAI API

## Dependencies
- OpenAI gem (`openai` gem)
- OpenAI::Client class
- RubyLLM::Schema for structured responses
- Services::Ai::Providers::BaseStrategy (parent class)

## Configuration
Uses OpenAI gem's default configuration:
- API key from `OPENAI_API_KEY` environment variable
- Default API base URL
- Default timeout and retry settings

## Models Supported
- GPT-4 (default)
- GPT-4 Turbo
- GPT-3.5 Turbo
- Any OpenAI chat completion model

## Design Notes
This strategy leverages OpenAI's native JSON schema support for structured outputs when available, falling back to JSON mode for simpler structured responses. The client is memoized to avoid repeated instantiation while maintaining thread safety. 