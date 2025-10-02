# Services::Ai::Providers::BaseStrategy

## Summary
Abstract base class for AI provider strategies. Provides common functionality and enforces the provider interface through abstract methods. Implements the template method pattern for AI interactions.

## Public Methods

### `#send_message!(ai_chat:, content:, response_format:, schema:, reasoning: nil)`
Template method that orchestrates the AI interaction flow

**Flow:**
1. Appends user message to chat history
2. Builds API parameters via `build_parameters`
3. **Saves parameters to `ai_chat.parameters` BEFORE making API call**
4. Makes API call via provider-specific `make_api_call`
5. Formats response via provider-specific `format_response`

- Parameters:
  - `ai_chat` (AiChat) - The chat context with history and configuration
  - `content` (String) - The message content to send
  - `response_format` (Hash, optional) - Provider-specific response format options (e.g., `{type: "json_object"}`)
  - `schema` (Class, optional) - Schema class for structured outputs (OpenAI::BaseModel or RubyLLM::Schema)
  - `reasoning` (Hash, optional) - Reasoning configuration (OpenAI-specific, e.g., `{effort: "low"}`)
- Returns: Hash with `:content`, `:parsed`, `:id`, `:model`, `:usage` keys
- Side effects:
  - Updates `ai_chat.parameters` with the request parameters
  - Saves `ai_chat` to database
  - Makes API call to provider

## Protected Methods (Abstract)

### `#client`
**Must be implemented by subclasses** - Returns the API client instance
- Returns: Provider-specific client object
- Raises: NotImplementedError if not implemented

### `#make_api_call(parameters)`
**Must be implemented by subclasses** - Makes the actual API call
- Parameters: parameters (Hash) - API call parameters
- Returns: Provider-specific response object
- Raises: NotImplementedError if not implemented

### `#format_response(response, schema)`
**Must be implemented by subclasses** - Formats the provider response into standard structure
- Parameters: 
  - `response` - Provider-specific response object
  - `schema` (Class, optional) - RubyLLM::Schema class for validation
- Returns: Hash with `:content`, `:parsed`, `:id`, `:model`, `:usage` keys
- Raises: NotImplementedError if not implemented

## Protected Methods (Overridable)

### `#build_parameters(model:, messages:, temperature:, response_format:, schema:, reasoning: nil)`
Builds API parameters from chat context and options. These parameters are saved to the AiChat before making the API call.

- Parameters:
  - `model` (String) - AI model identifier
  - `messages` (Array) - Chat message history
  - `temperature` (Float) - Response randomness control (0.0-2.0)
  - `response_format` (Hash, optional) - Format options (e.g., `{type: "json_object"}`)
  - `schema` (Class, optional) - Response schema class
  - `reasoning` (Hash, optional) - Reasoning configuration (provider-specific)
- Returns: Hash with basic parameters (`model`, `messages`, `temperature`)
- Override: Subclasses should override to add provider-specific parameters (see OpenaiStrategy for example)

### `#parse_response(content, schema)`
Common JSON parsing logic with error handling
- Parameters: 
  - `content` (String) - Raw JSON response content
  - `schema` (Class, optional) - RubyLLM::Schema for validation
- Returns: Hash with symbolized keys, or empty hash for nil/empty content
- Raises: JSON::ParserError for invalid JSON

## Usage Pattern
```ruby
class MyProviderStrategy < Services::Ai::Providers::BaseStrategy
  def capabilities = [:json_mode]
  def default_model = "my-model"
  def provider_key = :my_provider

  protected

  def client
    @client ||= MyProvider::Client.new
  end

  def make_api_call(parameters)
    client.chat.completions.create(parameters)
  end

  def format_response(response, schema)
    {
      content: response.content,
      parsed: parse_response(response.content, schema),
      id: response.id,
      model: response.model,
      usage: response.usage
    }
  end
end
```

## Subclasses
- `Services::Ai::Providers::OpenaiStrategy` - OpenAI implementation
- `Services::Ai::Providers::AnthropicStrategy` - Anthropic implementation (planned)
- `Services::Ai::Providers::GeminiStrategy` - Google Gemini implementation (planned)

## Dependencies
- Services::Ai::ProviderStrategy module
- JSON parsing capabilities
- Provider-specific API clients (implemented by subclasses)

## Design Notes
This class uses the Template Method pattern to provide a consistent interface while allowing provider-specific customization. The abstract methods ensure that all providers implement the minimum required functionality, while the overridable methods provide extension points for provider-specific behavior. 