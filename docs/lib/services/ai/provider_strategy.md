# Services::Ai::ProviderStrategy

## Summary
Interface module that defines the contract for AI provider implementations. All AI provider strategies must include this module and implement its required methods.

## Public Methods

### `#send_message!(ai_chat:, content:, response_format:, schema:)`
**Required implementation** - Sends a message to the AI provider and returns a structured response
- Parameters: 
  - `ai_chat` (AiChat) - The chat context with history and configuration
  - `content` (String) - The message content to send
  - `response_format` (Hash, optional) - Provider-specific response format options
  - `schema` (Class, optional) - RubyLLM::Schema class for structured responses
- Returns: Hash with `:content`, `:parsed`, `:id`, `:model`, `:usage` keys
- Side effects: Makes API call to external provider

### `#capabilities`
**Required implementation** - Returns array of supported features
- Returns: Array of symbols (e.g., `[:json_mode, :json_schema, :function_calls]`)

### `#default_model`
**Required implementation** - Returns the default model for this provider
- Returns: String (e.g., "gpt-4", "claude-3-sonnet")

### `#provider_key`
**Required implementation** - Returns the provider identifier
- Returns: Symbol that matches AiChat provider enum (e.g., `:openai`, `:anthropic`)

## Usage Pattern
```ruby
class MyProviderStrategy
  include Services::Ai::ProviderStrategy

  def capabilities = [:json_mode]
  def default_model = "my-model-v1"
  def provider_key = :my_provider

  def send_message!(ai_chat:, content:, response_format:, schema:)
    # Implementation specific to this provider
  end
end
```

## Implementing Classes
- `Services::Ai::Providers::BaseStrategy` - Abstract base class
- `Services::Ai::Providers::OpenaiStrategy` - OpenAI implementation
- `Services::Ai::Providers::AnthropicStrategy` - Anthropic implementation (planned)
- `Services::Ai::Providers::GeminiStrategy` - Google Gemini implementation (planned)

## Dependencies
- AiChat model for chat context
- RubyLLM::Schema for structured responses
- Provider-specific API clients (OpenAI, Anthropic, etc.)

## Design Notes
This interface enables the Strategy pattern for AI providers, allowing easy swapping of providers without changing client code. The contract ensures consistent behavior across all providers while allowing for provider-specific optimizations. 