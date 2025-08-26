# AI Services

## Overview
The Greatest uses a comprehensive AI service system for content enrichment, data validation, and intelligent processing across multiple media types. The system supports multiple AI providers (OpenAI, Anthropic, Google AI) through a strategy pattern that enables easy provider switching and task-specific optimizations.

## Key Features
- **Multi-Provider Support**: OpenAI, Anthropic, Google AI with unified interface
- **Task-Specific Optimization**: Tasks can specify preferred providers and models
- **Capability Detection**: Graceful fallback when providers lack specific features
- **Structured Responses**: JSON schema validation with RubyLLM integration
- **Complete Chat Tracking**: Full conversation history stored in database
- **Error Handling**: Explicit success/failure results without exceptions

## System Architecture

### Core Components
1. **Provider Strategy Pattern** - Pluggable AI provider implementations
2. **Task System** - Reusable AI task templates with customizable behavior
3. **Chat Tracking** - Comprehensive logging of all AI interactions
4. **Result Pattern** - Explicit success/failure handling
5. **Capability Detection** - Provider-aware feature usage

### Data Flow
```
Task Request → Provider Selection → Chat Creation → AI API Call → Response Processing → Result
```

1. Task initialized with parent entity and optional provider/model overrides
2. Provider strategy selected based on task preferences or global default
3. AiChat record created with configuration and system messages
4. Provider strategy handles API call with capability-aware parameters
5. Response processed, validated, and persisted to parent entity
6. Complete conversation and metadata stored in AiChat

## Current Implementation

### Provider Strategies
- **OpenAI Strategy** (`providers/openai_strategy.md`) - Full feature support (JSON schema, function calls)
- **Anthropic Strategy** (planned) - JSON mode with prompt-based schema
- **Google AI Strategy** (planned) - Basic capabilities with fallbacks

### Task Types
- **Artist Details** (`tasks/artist_details_task.md`) - Extract artist information and metadata
- **Author Information** (planned) - Book author details and validation
- **Content Analysis** (planned) - Media content analysis and summarization
- **Duplicate Detection** (planned) - Identify duplicate entries across catalogs

### Capability Matrix
| Feature | OpenAI | Anthropic | Google AI |
|---------|--------|-----------|-----------|
| JSON Mode | ✅ | ✅ | ✅ |
| JSON Schema | ✅ | ❌ (fallback) | ❌ (fallback) |
| Function Calls | ✅ | ❌ | ❌ |

## Chat Tracking System

### AiChat Model
Every AI interaction creates an `AiChat` record with:
- **Polymorphic Association**: Links to any model (artists, albums, books, etc.)
- **Provider Metadata**: Model, temperature, capabilities used
- **Complete History**: All messages in conversation thread
- **Raw Responses**: Full provider response data for debugging
- **Usage Tracking**: Token counts and API costs

### Chat Types
- `:general` - Basic AI interactions
- `:ranking` - Content ranking and scoring
- `:recommendation` - Personalized recommendations
- `:analysis` - Content analysis and enrichment

## Provider Strategy Pattern

### Strategy Interface
All providers implement `ProviderStrategy` interface:
```ruby
module ProviderStrategy
  def send_message!(ai_chat:, content:, response_format:, schema:)
  def capabilities
  def default_model
  def provider_key
end
```

### Provider Registry
Central registry manages active provider:
```ruby
# Switch providers globally
Services::Ai::ProviderRegistry.use!(:anthropic)

# Tasks can override per-instance
task = ArtistDetailsTask.new(parent: artist, provider: :openai)
```

## Task System

### Base Task Template
All AI tasks inherit from `BaseTask` which provides:
- **Consistent Workflow**: Chat creation, messaging, response processing
- **Capability Detection**: Automatic fallbacks for missing provider features
- **Error Handling**: Standardized result objects with success/failure states
- **Customization Hooks**: Override points for task-specific behavior

### Task Implementation Pattern
```ruby
class MyTask < BaseTask
  private
  
  def task_provider = :openai      # Preferred provider
  def task_model = "gpt-4"         # Preferred model
  def chat_type = :analysis        # Chat categorization
  
  def user_prompt                  # Required: task prompt
    "Analyze #{parent.name}"
  end
  
  def response_schema              # Optional: structured response
    MyResponseSchema
  end
  
  def process_and_persist(response) # Optional: handle results
    data = response[:parsed]
    parent.update!(data)
    Result.new(success: true, data: data, ai_chat: chat)
  end
end
```

## Capability Detection

### Feature Fallbacks
The `Capable` mixin enables automatic fallbacks:
- **JSON Schema**: Falls back to prompt instructions when not natively supported
- **Structured Output**: Degrades gracefully to text parsing
- **Provider Features**: Tasks adapt to available capabilities

### Example Usage
```ruby
class FlexibleTask < BaseTask
  def user_prompt
    if supports?(:json_schema)
      "Extract data"  # Rely on native schema
    else
      "Extract data as JSON: #{schema.to_json}"  # Add schema to prompt
    end
  end
end
```

## Result Pattern

### Explicit Success/Failure
All AI operations return `Result` objects:
```ruby
result = ArtistDetailsTask.new(parent: artist).call

if result.success?
  puts "Data: #{result.data}"
  puts "Chat: #{result.ai_chat.id}"
else
  puts "Error: #{result.error}"
end
```

### Benefits
- **No Hidden Exceptions**: Explicit error handling required
- **Rich Context**: Full chat history available for debugging
- **Composable Operations**: Easy to chain results
- **Audit Trail**: Complete record of AI interactions

## Configuration Files

### Core Architecture
- [`provider_strategy.md`](provider_strategy.md) - Provider interface contract
- [`provider_registry.md`](provider_registry.md) - Provider management system
- [`capable.md`](capable.md) - Capability detection and fallbacks
- [`result.md`](result.md) - Standardized result objects

### Provider Implementations
- [`providers/base_strategy.md`](providers/base_strategy.md) - Abstract base class
- [`providers/openai_strategy.md`](providers/openai_strategy.md) - OpenAI integration

### Task Framework
- [`tasks/base_task.md`](tasks/base_task.md) - Task template and workflow
- [`tasks/artist_details_task.md`](tasks/artist_details_task.md) - Artist information extraction

## Performance Optimizations
- **Provider Memoization**: Reuse API clients across requests
- **Conditional Updates**: Only persist when AI is confident about data
- **Structured Outputs**: Reduce parsing overhead with native JSON
- **Capability Caching**: Cache provider capabilities to avoid repeated checks

## Future Expansion
The architecture supports easy addition of:
- **New Providers**: Implement strategy interface and register
- **New Task Types**: Inherit from BaseTask with domain-specific logic
- **Advanced Features**: Function calling, embeddings, image analysis
- **Background Processing**: Queue long-running AI tasks
- **User-Facing Chat**: Interactive AI features for end users

## Related Implementation Details
- AI chat model implementation: [Todo #012](../../todos/012-ai-chats-model.md)
- AI service architecture: [Todo #013](../../todos/013-ai-chat-service.md)

## Dependencies
- **OpenAI gem**: GPT model access
- **Anthropic gem**: Claude model access (planned)
- **RubyLLM**: JSON schema definitions and validation
- **PostgreSQL**: JSONB storage for chat messages
- **AiChat model**: Conversation persistence

## Usage Examples

### Basic Task Execution
```ruby
# Use default provider
result = ArtistDetailsTask.new(parent: artist).call

# Override provider
result = ArtistDetailsTask.new(parent: artist, provider: :openai).call

# Check results
if result.success?
  puts "Updated artist: #{result.data}"
else
  puts "Failed: #{result.error}"
end
```

### Provider Switching
```ruby
# Switch globally
Services::Ai::ProviderRegistry.use!(:anthropic)

# All tasks now use Anthropic by default
result = ArtistDetailsTask.new(parent: artist).call
```

### Custom Task Creation
```ruby
class BookSummaryTask < BaseTask
  private
  
  def task_provider = :anthropic
  def chat_type = :analysis
  
  def user_prompt
    "Summarize this book: #{parent.title}"
  end
  
  def process_and_persist(response)
    parent.update!(ai_summary: response[:content])
    Result.new(success: true, data: { summary: response[:content] }, ai_chat: chat)
  end
end
```