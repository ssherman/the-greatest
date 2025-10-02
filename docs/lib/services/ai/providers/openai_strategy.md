# Services::Ai::Providers::OpenaiStrategy

## Summary
OpenAI API implementation of the AI provider strategy. Uses OpenAI's Responses API with support for structured outputs, flex processing for cost optimization, and optional reasoning parameter.

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
Makes Responses API call to OpenAI
- Parameters: parameters (Hash) - API parameters including model, input, temperature, service_tier, etc.
- Returns: OpenAI responses response object
- API: Uses `client.responses.create(parameters)`

### `#format_response(response, schema)`
Formats OpenAI response into standard structure
- Parameters:
  - `response` - OpenAI responses response
  - `schema` (Class, optional) - RubyLLM::Schema (not used, data is pre-parsed)
- Returns: Hash with `:content`, `:parsed`, `:id`, `:model`, `:usage` keys
- Processing: Extracts from `response.output.first.content.first.parsed` (already validated by OpenAI)

### `#build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning:)`
Builds OpenAI-specific API parameters for Responses API
- Parameters:
  - `model` (String) - GPT model identifier
  - `messages` (Array) - Chat message history with roles
  - `temperature` (Float) - Response randomness (0-2)
  - `response_format` (Hash, optional) - Ignored (Responses API uses `text` instead)
  - `schema` (Class, optional) - RubyLLM::Schema class
  - `reasoning` (Hash, optional) - Reasoning configuration (e.g., `{effort: "low"}`)
- Returns: Hash with OpenAI Responses API parameters
- OpenAI-specific transformations:
  - System messages → `instructions` parameter
  - User/assistant messages → `input` (array or string)
  - Single user message → simple string `input`
  - Multiple messages → array `input`
  - Adds `service_tier: "flex"` by default
  - Strips timestamps from messages

## Response Format Handling

### Structured Outputs with Responses API
When `schema` is provided and inherits from `RubyLLM::Schema`:
```ruby
schema_hash = JSON.parse(schema.new.to_json)
parameters[:text] = {
  format: {
    type: "json_schema",
    name: schema_hash["name"],
    strict: schema_hash["schema"]["strict"],
    schema: schema_hash["schema"]
  }
}
# Wraps RubyLLM::Schema in Responses API format structure
# OpenAI Responses API handles schema natively
# Response data is automatically parsed and validated
```

### Flex Processing
All requests use flex service tier by default:
```ruby
parameters[:service_tier] = "flex"
# Uses OpenAI's spare capacity for cost savings
```

### Reasoning Parameter (Optional)
Tasks can override the `reasoning` method to control reasoning effort:
```ruby
def reasoning
  { effort: "low" }  # or "medium", "high"
end
# Only supported by OpenAI, ignored by other providers
```

## Usage Examples

### Basic request with system message
```ruby
# Chat with system message: [{role: "system", content: "You are helpful"}]
strategy = Services::Ai::Providers::OpenaiStrategy.new
response = strategy.send_message!(
  ai_chat: chat,
  content: "Hello, world!",
  response_format: nil,
  schema: nil,
  reasoning: nil
)
# API call: { instructions: "You are helpful", input: "Hello, world!", ... }
```

### With structured outputs (JSON schema)
```ruby
class MySchema < RubyLLM::Schema
  string :name, required: true
  integer :age, required: false
end

response = strategy.send_message!(
  ai_chat: chat,
  content: "Extract person details",
  response_format: nil,
  schema: MySchema,
  reasoning: nil
)
# API call: { text: MySchema, input: "Extract...", ... }
# Returns pre-parsed and validated data in response[:parsed]
```

### With reasoning parameter
```ruby
response = strategy.send_message!(
  ai_chat: chat,
  content: "Complex problem solving task",
  response_format: nil,
  schema: MySchema,
  reasoning: { effort: "high" }
)
# API call: { reasoning: {effort: "high"}, ... }
# Uses extended reasoning for better quality
```

### Multi-turn conversation
```ruby
# Chat with history: [
#   {role: "system", content: "You are helpful"},
#   {role: "user", content: "Hello"},
#   {role: "assistant", content: "Hi there!"}
# ]
response = strategy.send_message!(
  ai_chat: chat,
  content: "What's the weather?",
  response_format: nil,
  schema: nil
)
# API call: {
#   instructions: "You are helpful",
#   input: [
#     {role: "user", content: "Hello"},
#     {role: "assistant", content: "Hi there!"},
#     {role: "user", content: "What's the weather?"}
#   ],
#   ...
# }
```

## Error Handling
- Network errors: Propagated from OpenAI::Client
- API errors: Propagated with OpenAI error details
- Invalid parameters: Validated by OpenAI Responses API
- Schema validation: Handled automatically by OpenAI (no manual JSON parsing needed)

## Dependencies
- OpenAI gem (`openai` gem v7.0+)
- OpenAI::Client class with Responses API support
- RubyLLM::Schema for structured outputs
- Services::Ai::Providers::BaseStrategy (parent class)

## Configuration
Uses OpenAI gem's default configuration:
- API key from `OPENAI_API_KEY` environment variable
- Default API base URL
- Default timeout and retry settings
- Flex processing enabled by default for cost optimization

## Models Supported
- gpt-5-mini (default)
- GPT-4 Turbo
- GPT-4
- Any OpenAI model supporting Responses API

## Design Notes
This strategy uses OpenAI's Responses API which provides:
1. **Native structured outputs**: Schema validation happens server-side, data arrives pre-parsed
2. **Flex processing**: Uses spare compute capacity for ~50% cost reduction with minimal latency impact
3. **Reasoning parameter**: Optional per-task control over reasoning effort (OpenAI-only feature)
4. **Cleaner API**: `input` instead of `messages`, `text` instead of complex `response_format` wrappers

The client is memoized to avoid repeated instantiation while maintaining thread safety. 