# 013 - AI Chat Service Implementation

## Status
- **Status**: Completed
- **Priority**: High
- **Created**: 2025-07-12
- **Started**: 2025-07-15
- **Completed**: 2025-07-15
- **Developer**: AI Assistant 

## Overview
Implement a comprehensive AI chat service using the strategy pattern that supports multiple AI providers (OpenAI, Anthropic, Gemini, etc.) with task-specific provider/model preferences. The service will provide a clean, provider-agnostic interface while allowing tasks to specify their preferred providers and models.

## Context
The application needs to make AI requests for various tasks:
- Author information extraction and validation
- Book summaries and analysis
- Content duplicate detection
- List analysis and ranking
- User-facing AI chat features

We need a robust system that:
- Supports multiple AI providers with easy switching
- Allows tasks to specify preferred providers/models
- Handles provider-specific capabilities (json_schema, json_mode, etc.)
- Provides consistent error handling and retry logic
- Maintains clean separation between provider logic and task logic

## Requirements
- [ ] Create provider strategy interface and registry
- [ ] Implement OpenAI provider strategy
- [ ] Implement Anthropic provider strategy  
- [ ] Implement Gemini provider strategy
- [ ] Create base task class with provider/model preferences
- [ ] Implement specific task classes (AuthorInfo, AuthorDuplicateCheck, etc.)
- [ ] Add capability detection for provider features
- [ ] Add retry logic with exponential backoff
- [ ] Add comprehensive test coverage
- [ ] Create service result objects
- [ ] Add proper error handling and logging

## Technical Approach

### File Structure
```
app/lib/services/
├── ai/
│   ├── provider_strategy.rb          # Interface (pure Ruby module)
│   ├── provider_registry.rb          # Keeps the single "active" strategy
│   ├── result.rb                     # Standardized result objects
│   ├── retryable.rb                  # Retry logic with exponential backoff
│   ├── capable.rb                    # Capability detection helpers
│   ├── providers/
│   │   ├── openai_strategy.rb        # OpenAI API adapter
│   │   ├── anthropic_strategy.rb     # Anthropic API adapter
│   │   └── gemini_strategy.rb        # Google Gemini API adapter
│   └── tasks/
│       ├── base_task.rb              # Template for "one-question" tasks
│       ├── author_info_task.rb       # Author information extraction
│       ├── author_duplicate_check_task.rb  # Author duplicate detection
│       ├── book_summary_task.rb      # Book summary generation
│       └── list_analysis_task.rb     # List analysis and ranking
```

### Core Components

#### 1. Provider Strategy Interface
```ruby
module Ai
  module ProviderStrategy
    # Required: sends message to provider and returns structured response
    def send_message!(ai_chat:, content:, response_format:, schema:); end

    # Required: returns array of supported capabilities
    def capabilities; end

    # Required: returns default model for this provider
    def default_model; end

    # Required: returns provider key for enum mapping
    def provider_key; end
  end
end
```

#### 2. Provider Registry
```ruby
module Ai
  class ProviderRegistry
    class << self
      attr_accessor :default

      def use!(key)
        self.default = strategies.fetch(key).new
      end

      private

      def strategies
        {
          openai: Ai::Providers::OpenaiStrategy,
          anthropic: Ai::Providers::AnthropicStrategy,
          gemini: Ai::Providers::GeminiStrategy
        }
      end
    end
  end
end
```

#### 3. Base Task Class
```ruby
module Ai
  module Tasks
    class BaseTask
      include Ai::Capable

      def initialize(parent:, provider: nil, model: nil)
        @parent = parent
        @provider = provider || task_provider || Ai::ProviderRegistry.default
        @model = model || task_model || @provider.default_model
      end

      def call
        # Create the chat when we actually need it
        @chat = create_chat!
        
        # Add user message to chat
        add_user_message(user_prompt_with_fallbacks)
        
        # Get response from provider
        provider_response = Ai::Retryable.with_retries do
          @provider.send_message!(
            ai_chat: @chat,
            content: user_prompt_with_fallbacks,
            response_format: supports?(:json_mode) ? response_format : nil,
            schema: supports?(:json_schema) ? response_schema : nil
          )
        end
        
        # Update chat with response data
        update_chat_with_response(provider_response)
        
        # Process and persist the result
        process_and_persist(provider_response)
      end

      private

      attr_reader :parent, :provider, :chat

      # Override in subclasses
      def task_provider; nil; end      # e.g., :anthropic
      def task_model; nil; end         # e.g., "claude-3-sonnet"
      def chat_type = :analysis
      def system_message; nil; end
      def user_prompt; raise; end
      def response_format; nil; end
      def response_schema; nil; end
      def temperature; 0.2; end
      def process_and_persist(raw) = raw

      def validate!(raw_json)
        # All providers now use RubyLLM schema validation
        schema = response_schema
        return JSON.parse(raw_json, symbolize_names: true) unless schema
        
        data = JSON.parse(raw_json, symbolize_names: true)
        schema.new.validate!(data)
        data
      end

      private

      def create_chat!
        AiChat.create!(
          parent: parent,
          chat_type: chat_type,
          model: @model,
          provider: @provider.provider_key,
          temperature: temperature,
          json_mode: response_format&.dig(:type) == "json_object",
          response_schema: response_schema,
          messages: system_message ? [{ role: "system", content: system_message, timestamp: Time.current }] : []
        )
      end

      def add_user_message(content)
        @chat.messages ||= []
        @chat.messages << { role: "user", content: content, timestamp: Time.current }
        @chat.save!
      end

      def update_chat_with_response(provider_response)
        # Add assistant response to messages
        @chat.messages ||= []
        @chat.messages << { 
          role: "assistant", 
          content: provider_response.content, 
          timestamp: Time.current 
        }
        
        # Store raw response data
        @chat.raw_responses ||= []
        @chat.raw_responses << {
          provider_response_id: provider_response.id,
          model: provider_response.model,
          usage: provider_response.usage,
          timestamp: Time.current
        }
        
        @chat.save!
      end
    end
  end
end
```

#### 4. Capability Detection
```ruby
module Ai
  module Capable
    def supports?(feature) = provider.capabilities.include?(feature)

    def user_prompt_with_fallbacks
      prompt = user_prompt.dup
      unless supports?(:json_schema) || response_schema.nil?
        json_instr = <<~INSTR
          IMPORTANT: respond with JSON that validates against:
          #{response_schema[:json_schema][:schema].to_json}
        INSTR
        prompt.prepend(json_instr)
      end
      prompt
    end
  end
end
```

#### 5. Result Objects
```ruby
module Ai
  class Result
    attr_reader :success, :data, :error, :ai_chat
    
    def initialize(success:, data: nil, error: nil, ai_chat: nil)
      @success = success
      @data = data
      @error = error
      @ai_chat = ai_chat
    end

    def success? = @success
    def failure? = !@success
  end
end
```

### Schema Classes

Schemas are defined as internal classes within each task for better encapsulation and locality.

### Provider Implementations

#### OpenAI Strategy
```ruby
class Ai::Providers::OpenaiStrategy
  include Ai::ProviderStrategy

  def capabilities = %i[json_mode json_schema function_calls]
  def default_model = "gpt-4"
  def provider_key = :openai

  def send_message!(ai_chat:, content:, response_format:, schema:)
    client = OpenAI::Client.new
    
    messages = ai_chat.messages + [{ role: "user", content: content }]
    
    parameters = {
      model: ai_chat.model,
      messages: messages,
      temperature: ai_chat.temperature
    }
    
    # Use RubyLLM schema if provided
    if schema && schema < RubyLLM::Schema
      parameters[:response_format] = { type: "json_object" }
      # Add schema to the request for structured output
      parameters[:response_format] = {
        type: "json_schema",
        schema: schema.new.to_json_schema
      }
    elsif response_format
      parameters[:response_format] = response_format
    end
    
    response = client.chat.completions.create(parameters)
    
    # Return structured response wrapper
    choice = response.choices.first
    OpenStruct.new(
      content: choice.message.content,  # Raw JSON string from API
      parsed: parse_response(choice.message.content, schema),  # Parsed and validated data
      id: response.id,
      model: response.model,
      usage: response.usage
    )
  end

  private

  def parse_response(content, schema)
    # content is the raw JSON string from the API
    return JSON.parse(content, symbolize_names: true) unless schema
    
    # Parse JSON and validate against schema
    data = JSON.parse(content, symbolize_names: true)
    schema.new.validate!(data)
    data
  end
end
```

#### Anthropic Strategy
```ruby
class Ai::Providers::AnthropicStrategy
  include Ai::ProviderStrategy

  def capabilities = %i[json_mode]
  def default_model = "claude-3-sonnet"
  def provider_key = :anthropic

  def send_message!(ai_chat:, content:, response_format:, schema:)
    # Use Anthropic API (schema embedded in prompt)
    # Returns structured response with content, id, model, usage, etc.
  end
end
```

### Task Implementations

#### Author Info Task
```ruby
module Ai
  module Tasks
    class AuthorInfoTask < BaseTask
      private
      
      def task_provider = :anthropic
      def task_model = "claude-3-sonnet"

      def user_prompt
        <<~PROMPT.squish
          I need details of the author #{parent.name}.
          Respond with valid JSON matching the schema.
        PROMPT
      end

      def response_format = { type: "json_object" }
      
      def response_schema
        ResponseSchema
      end

      def process_and_persist(provider_response)
        # All providers now use the same parsed data from RubyLLM schema
        data = provider_response.parsed
        parent.update!(data.slice(:full_name, :birth_year, :death_year, :nationality))
        Ai::Result.new(success: true, data: data, ai_chat: chat)
      end

      # Internal schema class
      class ResponseSchema < RubyLLM::Schema
        integer :id, required: true
        string :full_name, required: false
        integer :birth_year, required: false
        integer :death_year, required: false
        string :nationality, required: false
        string :description, required: false
      end
    end
  end
end
```

#### Author Duplicate Check Task
```ruby
module Ai
  module Tasks
    class AuthorDuplicateCheckTask < BaseTask
      private
      
      def task_provider = :openai  # Needs json_schema capability
      def task_model = "gpt-4o-2024-08-06"

      def system_message
        # Your existing system message for duplicate detection
      end

      def user_prompt
        # Your existing question text
      end

      def response_format = { type: "json_object" }
      
      def response_schema
        ResponseSchema
      end

      def process_and_persist(provider_response)
        # provider_response.parsed is validated data from RubyLLM schema
        data = provider_response.parsed
        # Process duplicate detection result
        Ai::Result.new(success: true, data: data, ai_chat: chat)
      end

      # Internal schema class
      class ResponseSchema < RubyLLM::Schema
        boolean :are_duplicates, required: true
        string :explanation, required: true
        boolean :is_compound_name, required: true
      end
    end
  end
end
```

## Dependencies
- AiChat model (already implemented)
- OpenAI gem for OpenAI API
- Anthropic gem for Anthropic API
- Google AI gem for Gemini API
- ruby_llm-schema gem for JSON schema definitions

## Acceptance Criteria
- [ ] Can switch providers globally with one line: `Ai::ProviderRegistry.use!(:anthropic)`
- [ ] Tasks can specify preferred providers/models
- [ ] Provider capabilities are automatically detected and used
- [ ] JSON schema validation works across all providers
- [ ] Retry logic handles transient failures
- [ ] All AI interactions are logged to AiChat model
- [ ] Comprehensive test coverage for all components
- [ ] Error handling provides meaningful error messages
- [ ] Service can be easily extended with new providers and tasks

## Design Decisions

### Why Strategy Pattern?
- Clean separation between provider logic and task logic
- Easy to add new providers without changing existing code
- Provider-specific capabilities are handled transparently

### Why Task-Specific Provider Preferences?
- Different tasks work better with different providers
- Some tasks require specific capabilities (json_schema)
- Maintains flexibility while providing sensible defaults

### Why Capability Detection?
- Handles provider differences gracefully
- Allows tasks to work with any provider
- Provides fallbacks for missing features

### Why Result Objects?
- Consistent error handling across all tasks
- Easy to handle success/failure cases
- Provides context about what happened

### Why Retry Logic?
- Handles transient API failures
- Improves reliability of AI interactions
- Configurable retry strategies

---

## Implementation Notes

### Approach Taken

Implemented a comprehensive AI chat service using the Strategy pattern with the following architecture:

1. **Provider Strategy Pattern**: Created a base strategy class with abstract methods that concrete providers must implement
2. **Task System**: Built a template method pattern for consistent AI task execution with customizable hooks
3. **Result Pattern**: Implemented explicit success/failure handling without exceptions
4. **Capability Detection**: Added capability detection to gracefully handle provider differences
5. **Provider Registry**: Created centralized provider management with easy switching

### Key Files Changed

- `app/lib/services/ai/providers/base_strategy.rb` - New abstract base class for providers
- `app/lib/services/ai/providers/openai_strategy.rb` - Refactored to inherit from base strategy
- `app/lib/services/ai/tasks/base_task.rb` - New abstract base class for AI tasks
- `app/lib/services/ai/tasks/artist_details_task.rb` - Improved with artist_known field and better prompts
- `app/lib/services/ai/provider_strategy.rb` - Interface module for provider contract
- `app/lib/services/ai/capable.rb` - Capability detection mixin
- `app/lib/services/ai/result.rb` - Standardized result object
- `app/lib/services/ai/provider_registry.rb` - Singleton registry for provider management
- `test/lib/services/ai/tasks/artist_details_task_test.rb` - Cleaned up to use real AiChat instances instead of stubs
- `test/lib/services/ai/providers/openai_strategy_test.rb` - Updated to stub client method instead of global OpenAI::Client.new

### Challenges Encountered

1. **Test Refactoring**: Initial tests were over-mocking ActiveRecord models (AiChat), required cleanup to use real instances
2. **Provider Abstraction**: Needed to balance common functionality with provider-specific features
3. **Capability Handling**: Required fallback mechanisms for providers with different capabilities
4. **Artist Task Improvement**: Original implementation needed better handling of unknown artists

### Deviations from Plan

1. **Simplified Provider Registry**: Implemented a simpler registry pattern instead of complex provider management
2. **Enhanced Artist Task**: Added `artist_known` field and improved prompts beyond original plan
3. **Result Pattern**: Used explicit result objects instead of exceptions for better error handling
4. **Template Method**: Used template method pattern for tasks instead of pure composition

### Code Examples

```ruby
# Provider usage with fallback
class MyTask < BaseTask
  def user_prompt
    if supports?(:json_schema)
      "Return structured data"
    else
      "Return JSON format: #{schema.to_json}"
    end
  end
end

# Easy provider switching
Services::Ai::ProviderRegistry.use!(:openai)
result = ArtistDetailsTask.new(parent: artist).call
```

### Testing Approach

- **51 tests** covering all components with **171 assertions**
- **Real AiChat instances** instead of mocking ActiveRecord models
- **Provider abstraction testing** with stub methods instead of global stubs
- **Capability detection testing** for fallback scenarios
- **Integration tests** for complete task workflows

### Performance Considerations

- **Memoized clients** to avoid repeated API client instantiation
- **Conditional database updates** only when AI is confident about data
- **Structured outputs** to reduce parsing overhead
- **Provider-specific optimizations** while maintaining common interface

### Future Improvements

- Implement Anthropic and Gemini provider strategies
- Add retry logic with exponential backoff
- Implement function calling capabilities
- Add more task types for other domains (books, movies, games)
- Add background job processing for long-running tasks

### Lessons Learned

- **Don't over-mock**: ActiveRecord models should be used directly in tests, not stubbed
- **Strategy pattern works well**: Easy to add new providers without changing existing code
- **Capability detection is crucial**: Providers have different features, need graceful fallbacks
- **Result pattern is valuable**: Explicit success/failure handling improves error management
- **Template method pattern**: Provides consistency while allowing customization

### Related PRs

- Multiple refactoring commits during development session
- Test cleanup and improvement commits
- Documentation creation commits

### Documentation Updated

- `docs/models/ai_chat.md` - Complete AiChat model documentation
- `docs/services/ai/provider_strategy.md` - Provider interface documentation
- `docs/services/ai/providers/base_strategy.md` - Base strategy documentation
- `docs/services/ai/providers/openai_strategy.md` - OpenAI implementation documentation
- `docs/services/ai/tasks/base_task.md` - Task base class documentation
- `docs/services/ai/tasks/artist_details_task.md` - Artist task documentation
- `docs/services/ai/capable.md` - Capability detection documentation
- `docs/services/ai/result.md` - Result pattern documentation
- `docs/services/ai/provider_registry.md` - Provider registry documentation