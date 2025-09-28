# Services::Ai::ProviderRegistry

## Summary
Singleton registry for managing AI provider strategies. Provides centralized provider selection and configuration with support for global provider switching and default fallbacks.

## Class Methods

### `#default`
Gets the currently configured default provider
- Returns: Provider strategy instance (e.g., OpenaiStrategy instance)
- Usage: `Services::Ai::ProviderRegistry.default`
- Thread-safe: Yes

### `#default=(provider)`
Sets the default provider instance
- Parameters: provider (ProviderStrategy) - Strategy instance to use as default
- Usage: `Services::Ai::ProviderRegistry.default = strategy`
- Thread-safe: Yes

### `#use!(key)`
Configures the registry to use a specific provider
- Parameters: key (Symbol) - Provider key (e.g., `:openai`, `:anthropic`)
- Side effects: Sets default to new instance of specified provider
- Usage: `Services::Ai::ProviderRegistry.use!(:openai)`
- Raises: KeyError if provider key not found

## Available Providers

### `:openai`
OpenAI GPT models
- Class: `Services::Ai::Providers::OpenaiStrategy`
- Capabilities: JSON mode, JSON schema, function calls
- Default model: "gpt-4"

### `:anthropic`
Anthropic Claude models (planned)
- Class: `Services::Ai::Providers::AnthropicStrategy`
- Capabilities: JSON mode
- Default model: "claude-3-sonnet"

### `:gemini`
Google Gemini models (planned)
- Class: `Services::Ai::Providers::GeminiStrategy`
- Capabilities: JSON mode
- Default model: "gemini-pro"

## Usage Examples

### Setting Global Provider
```ruby
# Use OpenAI for all AI interactions
Services::Ai::ProviderRegistry.use!(:openai)

# Use Anthropic for all AI interactions
Services::Ai::ProviderRegistry.use!(:anthropic)
```

### Getting Current Provider
```ruby
provider = Services::Ai::ProviderRegistry.default
puts "Using: #{provider.class}"
puts "Model: #{provider.default_model}"
puts "Capabilities: #{provider.capabilities}"
```

### Provider-Specific Configuration
```ruby
# Switch to OpenAI for tasks requiring JSON schema
Services::Ai::ProviderRegistry.use!(:openai)
artist_task = ArtistDescriptionTask.new(parent: artist)
result = artist_task.call

# Switch to Anthropic for general conversations
Services::Ai::ProviderRegistry.use!(:anthropic)
general_task = GeneralChatTask.new(parent: user)
result = general_task.call
```

### Environment-Based Configuration
```ruby
# In initializer or configuration
case Rails.env
when 'development'
  Services::Ai::ProviderRegistry.use!(:openai)
when 'production'
  Services::Ai::ProviderRegistry.use!(:anthropic)
when 'test'
  Services::Ai::ProviderRegistry.use!(:openai)
end
```

## Integration with Tasks

### Default Provider Usage
```ruby
class MyTask < BaseTask
  # Uses whatever provider is configured in registry
  def call
    # @provider is set from registry during initialization
    super
  end
end
```

### Provider Override
```ruby
class MyTask < BaseTask
  def task_provider
    :openai  # Always use OpenAI regardless of registry
  end
end

# Or at runtime
task = MyTask.new(parent: artist, provider: :anthropic)
```

## Configuration Patterns

### Application Initialization
```ruby
# config/initializers/ai_providers.rb
Rails.application.configure do
  config.after_initialize do
    Services::Ai::ProviderRegistry.use!(:openai)
  end
end
```

### Feature Flags
```ruby
# Dynamic provider selection based on feature flags
if FeatureFlag.enabled?(:use_anthropic)
  Services::Ai::ProviderRegistry.use!(:anthropic)
else
  Services::Ai::ProviderRegistry.use!(:openai)
end
```

### A/B Testing
```ruby
# Provider selection for A/B testing
if experiment_group?(:ai_provider, :anthropic)
  Services::Ai::ProviderRegistry.use!(:anthropic)
else
  Services::Ai::ProviderRegistry.use!(:openai)
end
```

## Thread Safety
- All operations are thread-safe
- Provider instances are immutable after creation
- Registry state is stored in class variables with proper synchronization

## Error Handling
- `KeyError` raised for unknown provider keys
- `ArgumentError` raised for invalid provider instances
- Provider-specific errors propagated from underlying strategies

## Design Notes
This registry implements the Registry pattern to provide centralized provider management while maintaining flexibility for per-task overrides. It enables easy switching between providers for different environments, feature flags, or A/B testing scenarios. The singleton design ensures consistent provider selection across the application while allowing fine-grained control when needed. 