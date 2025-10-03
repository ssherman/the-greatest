# AI Agents Feature

## Overview
The AI Agents system provides a flexible, provider-agnostic framework for integrating Large Language Models (LLMs) across the application. It uses the strategy pattern to support multiple AI providers (OpenAI, Anthropic, Gemini) while maintaining a consistent interface for domain-specific tasks like content generation, data enrichment, and intelligent matching.

## Architecture

### Core Design Principles
- **Strategy Pattern**: Separates provider implementation (OpenAI, Anthropic) from task logic (description generation, matching)
- **Provider Agnostic**: Tasks work with any provider through a common interface
- **Structured Outputs**: Strong typing with schema validation for reliable data extraction
- **Cost Optimization**: Flex processing and model selection for efficient resource usage
- **Full Observability**: Complete request/response logging for debugging and analysis

### System Components

#### Base Classes (Provider-Agnostic)
- **BaseStrategy** - Abstract provider implementation with template method pattern
- **BaseTask** - Task orchestration with chat management and response processing
- **ProviderStrategy** - Interface contract that all providers must implement
- **Result** - Standardized success/failure response wrapper
- **Capable** - Mixin for capability detection and feature fallbacks

#### Provider Implementations
```
Services::Ai::Providers::
  - BaseStrategy (abstract)
  - OpenaiStrategy (Responses API with flex processing)
  - AnthropicStrategy (planned)
  - GeminiStrategy (planned)
```

#### Task Structure
```
Services::Ai::Tasks::
  - BaseTask (abstract)
  - Music::
      - ArtistDescriptionTask
      - AlbumDescriptionTask
      - AmazonAlbumMatchTask
  - Lists::
      - Books::RawParserTask
      - Movies::RawParserTask
      - Games::RawParserTask
      - Music::AlbumsRawParserTask
      - Music::SongsRawParserTask
```

### Key Features

#### Request Parameter Logging
All request parameters are saved **before** making the API call, ensuring:
- **Debugging Failed Requests**: See what was sent even if the API call fails
- **Parameter History**: Track which parameters were used for each request
- **Cost Analysis**: Analyze which parameter combinations are most cost-effective
- **Audit Trail**: Complete record of all AI interactions

#### Complete Response Storage
Full provider responses stored in `raw_responses`, not just token counts:
- **Content**: Raw text response from the API
- **Parsed**: Validated structured data (if using schema)
- **ID**: Provider's unique response identifier
- **Model**: Actual model used for the response
- **Usage**: Complete token usage statistics
- **Timestamp**: When the response was received

#### Provider Capabilities
Different providers support different features. The system handles this gracefully:
- **json_mode**: Basic JSON response formatting (all providers)
- **json_schema**: Server-side schema validation (OpenAI)
- **function_calls**: Tool/function calling (OpenAI, future providers)
- **reasoning**: Extended reasoning mode (OpenAI-specific)

#### Cost Optimization
- **Flex Processing**: OpenAI requests use "flex" service tier for ~50% cost reduction
- **Model Selection**: Tasks can specify optimal model per use case
- **Temperature Control**: Fine-tuned randomness settings per task type
- **Reasoning Levels**: Optional reasoning parameter for complex tasks

## Current Implementation

### Supported Providers
- **OpenAI** (Complete) - Using Responses API with flex processing
  - Models: gpt-5-mini (default), gpt-4o, gpt-4-turbo
  - Capabilities: json_mode, json_schema, function_calls, reasoning
  - Special Features: Native structured outputs, flex tier pricing

- **Anthropic** (Planned) - Claude models
- **Gemini** (Planned) - Google's AI models

### Supported Tasks

#### Content Generation
- **Music::ArtistDescriptionTask** - Generate artist biographies and metadata
- **Music::AlbumDescriptionTask** - Generate album descriptions and context
- Auto-abstention when AI lacks confidence

#### Data Matching
- **Music::AmazonAlbumMatchTask** - Match albums to Amazon products
- Fuzzy matching with confidence scores
- Structured output with match reasoning

#### List Parsing
- **Lists::Books::RawParserTask** - Extract book data from text
- **Lists::Movies::RawParserTask** - Extract movie data from text
- **Lists::Games::RawParserTask** - Extract game data from text
- **Lists::Music::AlbumsRawParserTask** - Extract album data from text
- **Lists::Music::SongsRawParserTask** - Extract song data from text

## Usage Examples

### Basic Task Execution
```ruby
# Generate artist description
result = Services::Ai::Tasks::Music::ArtistDescriptionTask.new(
  parent: artist
).call

if result.success?
  puts result.data[:description]
  puts "AI Chat ID: #{result.ai_chat.id}"
end
```

### With Custom Provider/Model
```ruby
# Use specific provider and model
result = Services::Ai::Tasks::Music::AlbumDescriptionTask.new(
  parent: album,
  provider: :openai,
  model: "gpt-4o"
).call
```

### Task with Reasoning
```ruby
class ComplexAnalysisTask < Services::Ai::Tasks::BaseTask
  private

  def reasoning
    { effort: "high" }  # Use extended reasoning
  end

  def user_prompt
    "Analyze this complex data: #{parent.data}"
  end
end
```

## Task Execution Flow

### Standard Task Flow
1. **Task Initialization**: Parent entity provided, provider/model selected
2. **Chat Creation**: AiChat record created with task configuration
3. **User Message Storage**: User prompt added to `chat.messages` array
4. **Parameter Building**: Provider builds request parameters
5. **Parameter Saving**: Parameters saved to AiChat **before** API call
6. **API Call**: Provider makes request to AI service
7. **Response Processing**: Provider formats response to standard structure
8. **Assistant Message Storage**: Assistant response added to `chat.messages` array
9. **Response Storage**: Complete response saved to `raw_responses`
10. **Task Processing**: Task-specific `process_and_persist` handles result
11. **Result Return**: Success/failure result with data and ai_chat reference

**Important**: Both user and assistant messages are stored in the conversation history, ensuring complete audit trail and enabling multi-turn conversations.

### Parameter Building (Provider-Specific)
OpenAI example:
```ruby
# Input: Messages, schema, temperature, reasoning
# Output: {
#   model: "gpt-5-mini",
#   temperature: 1.0,
#   service_tier: "flex",
#   instructions: "System message content",
#   input: "User message content",
#   text: SchemaClass,
#   reasoning: { effort: "low" }
# }
```

### Response Structure
All providers return standardized format:
```ruby
{
  content: "Raw text response...",
  parsed: { field1: "value1", field2: 123 },  # If using schema
  id: "chatcmpl-abc123",
  model: "gpt-4o",
  usage: {
    prompt_tokens: 150,
    completion_tokens: 85,
    total_tokens: 235
  }
}
```

## Schema Definitions

### Structured Output Pattern
Tasks define response schemas as internal classes:
```ruby
module Services::Ai::Tasks::Music
  class ArtistDescriptionTask < BaseTask
    private

    def response_schema
      ResponseSchema
    end

    class ResponseSchema < OpenAI::BaseModel
      required :description, String, nil?: true
      required :abstained, OpenAI::Boolean
      required :abstain_reason, String, nil?: true
    end
  end
end
```

### Schema Validation
- **OpenAI**: Server-side validation with native structured outputs
- **Other Providers**: Client-side validation with RubyLLM schemas
- **Automatic Fallback**: System handles provider capability differences

## Error Handling

### Provider Isolation
- API errors propagated with provider-specific details
- Network failures handled gracefully
- Tasks catch all errors and return failure results

### Comprehensive Logging
- All requests logged with parameters
- All responses stored completely
- Failed requests still have parameter records
- AiChat model tracks complete interaction history

### Graceful Degradation
- Providers can abstain from answering (confidence checking)
- Missing capabilities trigger fallback behaviors
- Schema validation errors provide clear feedback

## Extension Points

### Adding New Providers
1. Create provider class inheriting from `BaseStrategy`
2. Implement required methods: `client`, `make_api_call`, `format_response`
3. Override `build_parameters` for provider-specific params
4. Define capabilities array
5. Set default model and provider key

Example:
```ruby
class Services::Ai::Providers::AnthropicStrategy < BaseStrategy
  def capabilities = %i[json_mode]
  def default_model = "claude-3-sonnet"
  def provider_key = :anthropic

  protected

  def client
    @client ||= Anthropic::Client.new
  end

  def make_api_call(parameters)
    client.messages.create(parameters)
  end

  def format_response(response, schema)
    # Convert to standard format
  end
end
```

### Adding New Tasks
1. Create task class inheriting from `BaseTask`
2. Implement required method: `user_prompt`
3. Override optional methods: `task_provider`, `task_model`, `system_message`, `response_schema`
4. Implement `process_and_persist` to handle results

Example:
```ruby
class MyAnalysisTask < BaseTask
  private

  def task_provider = :openai
  def task_model = "gpt-4o"
  def chat_type = :analysis

  def system_message
    "You are an expert analyst."
  end

  def user_prompt
    "Analyze: #{parent.data}"
  end

  def response_schema
    ResponseSchema
  end

  def process_and_persist(provider_response)
    data = provider_response[:parsed]
    parent.update!(analysis: data[:result])
    create_result(success: true, data: data, ai_chat: chat)
  end

  class ResponseSchema < OpenAI::BaseModel
    string :result, required: true
  end
end
```

## Performance Considerations

### Efficiency Features
- **Memoized Clients**: API clients created once and reused
- **Flex Processing**: OpenAI flex tier reduces costs by ~50%
- **Model Selection**: Tasks use appropriate model for complexity
- **Temperature Tuning**: Lower randomness for structured tasks

### Cost Management
- **Default Model**: gpt-5-mini for most tasks
- **Upgrade When Needed**: Tasks specify gpt-4o for complex operations
- **Reasoning Budget**: Low/medium/high reasoning levels per task
- **Usage Tracking**: Complete token usage logged per request

### Monitoring
- **Request Parameters**: Logged before API call
- **Response Data**: Complete responses stored
- **Usage Statistics**: Token counts for cost analysis
- **Error Tracking**: Failed requests logged with context

## Data Model

### AiChat Model
Stores complete AI interaction history:
- **parent**: Polymorphic association to any entity
- **chat_type**: Enum (general, ranking, recommendation, analysis)
- **provider**: Enum (openai, anthropic, gemini, local)
- **model**: String (e.g., "gpt-4o")
- **temperature**: Decimal (0.0-2.0)
- **json_mode**: Boolean (JSON response requested)
- **parameters**: JSONB (request params saved before API call)
- **response_schema**: JSONB (schema definition used)
- **messages**: JSONB array (conversation history with timestamps)
- **raw_responses**: JSONB array (complete provider responses)

### Benefits of Complete Logging
- **Debugging**: See exact request/response for any AI interaction
- **Analysis**: Compare parameter combinations and their results
- **Audit**: Complete history of AI usage per entity
- **Optimization**: Identify which models/params work best

## Future Enhancements

### Planned Providers
- **Anthropic** - Claude 3 models for high-quality reasoning
- **Google Gemini** - Multimodal capabilities
- **Local Models** - Self-hosted options for privacy

### Planned Features
- **Function Calling**: Tool use for dynamic data access
- **Multimodal Tasks**: Image and audio processing
- **Streaming Responses**: Real-time output for long generations
- **Batch Processing**: Efficient handling of multiple items
- **Retry Logic**: Exponential backoff for transient failures
- **Rate Limiting**: Respect provider API constraints

### Scalability Improvements
- **Response Caching**: Cache common queries
- **Parallel Execution**: Process multiple tasks concurrently
- **Background Processing**: Async task execution via Sidekiq
- **Provider Fallback**: Switch providers on failure

## Related Documentation

For implementation details, see individual class documentation:
- [BaseStrategy](../lib/services/ai/providers/base_strategy.md) - Provider abstraction
- [OpenaiStrategy](../lib/services/ai/providers/openai_strategy.md) - OpenAI implementation
- [BaseTask](../lib/services/ai/tasks/base_task.md) - Task orchestration

For data model:
- [AiChat](../models/ai_chat.md) - Conversation storage and history

For specific tasks:
- Music::ArtistDescriptionTask - Artist content generation
- Music::AlbumDescriptionTask - Album content generation
- Music::AmazonAlbumMatchTask - Product matching
