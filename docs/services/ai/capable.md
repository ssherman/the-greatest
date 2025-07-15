# Services::Ai::Capable

## Summary
Mixin module that provides capability detection and prompt enhancement for AI tasks. Enables tasks to check provider capabilities and automatically enhance prompts when certain features are unavailable.

## Public Methods

### `#supports?(feature)`
Checks if the current provider supports a specific feature
- Parameters: feature (Symbol) - The capability to check (e.g., `:json_schema`, `:json_mode`)
- Returns: Boolean indicating feature support
- Usage: `supports?(:json_schema)` returns true/false

### `#user_prompt_with_fallbacks`
Enhances user prompt with fallback instructions for missing capabilities
- Returns: String with original prompt plus capability-specific fallbacks
- Side effects: None (pure function)
- Enhancement: Adds JSON schema instructions if schema provided but not natively supported

## Supported Capabilities

### `:json_mode`
Provider can return structured JSON responses
- OpenAI: ✅ Supported
- Anthropic: ✅ Supported
- Gemini: ✅ Supported

### `:json_schema`
Provider supports native JSON schema validation
- OpenAI: ✅ Supported (structured outputs)
- Anthropic: ❌ Not supported (fallback to prompt instructions)
- Gemini: ❌ Not supported (fallback to prompt instructions)

### `:function_calls`
Provider supports function calling
- OpenAI: ✅ Supported
- Anthropic: ❌ Not supported
- Gemini: ❌ Not supported

## Fallback Behavior

### JSON Schema Fallback
When schema is provided but `:json_schema` is not supported:
```ruby
def user_prompt_with_fallbacks
  prompt = user_prompt.dup
  unless supports?(:json_schema) || response_schema.nil?
    json_instr = <<~INSTR
      IMPORTANT: respond with JSON that validates against:
      #{response_schema.new.to_json_schema}
    INSTR
    prompt.prepend(json_instr)
  end
  prompt
end
```

## Usage Examples

### Checking capabilities
```ruby
class MyTask < BaseTask
  include Services::Ai::Capable

  def call
    if supports?(:json_schema)
      # Use native structured output
      use_native_schema
    else
      # Fall back to prompt instructions
      use_prompt_fallback
    end
  end
end
```

### Automatic prompt enhancement
```ruby
class MyTask < BaseTask
  include Services::Ai::Capable

  def user_prompt
    "Extract data from: #{parent.name}"
  end

  def response_schema
    MySchema
  end

  # This automatically gets enhanced with schema instructions
  # if the provider doesn't support native JSON schema
  def enhanced_prompt
    user_prompt_with_fallbacks
  end
end
```

## Design Patterns

### Capability-aware Task Design
```ruby
class FlexibleTask < BaseTask
  include Services::Ai::Capable

  def response_format
    if supports?(:json_schema)
      nil  # Use native schema support
    elsif supports?(:json_mode)
      { type: "json_object" }
    else
      nil  # Plain text response
    end
  end

  def user_prompt
    base_prompt = "Analyze #{parent.name}"
    
    if supports?(:json_schema) || supports?(:json_mode)
      "#{base_prompt} and return structured JSON"
    else
      "#{base_prompt} and format as plain text"
    end
  end
end
```

## Including Classes
- `Services::Ai::Tasks::BaseTask` - All task classes inherit this capability
- Any custom task implementations

## Dependencies
- Provider instance with `capabilities` method
- Response schema class (optional)
- Provider registry for capability detection

## Design Notes
This module enables graceful degradation when switching between AI providers with different capabilities. It abstracts capability differences so tasks can work with any provider while still taking advantage of advanced features when available. The fallback system ensures consistent behavior across providers while maintaining optimal performance with capable providers. 