module Services
  module Ai
    module Tasks
      class BaseTask
        include Services::Ai::Capable

        def initialize(parent:, provider: nil, model: nil)
          @parent = parent
          validate_parent!
          @role = Services::Ai::Roles.resolve(task_role)
          @provider = provider || create_provider(task_provider || @role.provider)
          @model = model || task_model || @role.model
        end

        def call
          # Create the chat when we actually need it
          @chat = create_chat!

          # Add user message to chat history
          user_content = user_prompt_with_fallbacks
          add_user_message(user_content)

          # Get response from provider
          provider_response = @provider.send_message!(
            ai_chat: @chat,
            content: user_content,
            response_format: supports?(:json_mode) ? response_format : nil,
            schema: supports?(:json_schema) ? response_schema : nil,
            reasoning: reasoning,
            tools: tools,
            force_tool: force_tool?
          )

          # Update chat with response data
          update_chat_with_response(provider_response)

          # Process and persist the result
          process_and_persist(provider_response)
        rescue => e
          Services::Ai::Result.new(success: false, error: e.message)
        end

        private

        attr_reader :parent, :provider, :chat, :role

        # Which entry of config.x.ai.roles this task runs on. Override in
        # subclasses; see config/initializers/ai.rb for what each role means.
        def task_role = :fast

        # Tools the provider should offer the model. The role supplies them
        # (research carries :web_search); a task may override to add its own.
        def tools = role.tools

        # When true the provider requires the first tool to be used.
        def force_tool? = false

        # Escape hatches: an explicit provider or model here beats the role.
        # No task in app/ overrides task_model any more.
        def task_provider  # e.g., :openai
          nil
        end

        def task_model
          nil
        end

        def chat_type = :analysis

        def system_message
          nil
        end

        def user_prompt
          raise
        end

        def response_format
          nil
        end

        def response_schema
          nil
        end

        def temperature
          1.0
        end

        def reasoning
          nil
        end

        def process_and_persist(raw) = raw

        def create_provider(key)
          case key&.to_sym
          when :openai
            Services::Ai::Providers::OpenaiStrategy.new
          # when :anthropic
          #   Services::Ai::Providers::AnthropicStrategy.new
          # when :gemini
          #   Services::Ai::Providers::GeminiStrategy.new
          else
            raise ArgumentError, "Unknown provider: #{key.inspect}"
          end
        end

        def validate!(raw_json)
          # Schemas are OpenAI::BaseModel subclasses; validate! is an instance method.
          schema = response_schema
          return JSON.parse(raw_json, symbolize_names: true) unless schema

          data = JSON.parse(raw_json, symbolize_names: true)
          schema.new.validate!(data)
          data
        end

        def validate_parent!
          raise ArgumentError, "Parent is required" unless parent
        end

        def create_result(success:, data: nil, error: nil, ai_chat: nil)
          Services::Ai::Result.new(success: success, data: data, error: error, ai_chat: ai_chat)
        end

        def create_chat!
          AiChat.create!(
            parent: parent,
            chat_type: chat_type,
            model: @model,
            provider: @provider.provider_key,
            temperature: temperature,
            json_mode: response_format&.dig(:type) == "json_object",
            response_schema: response_schema ? schema_to_json(response_schema) : nil,
            messages: system_message ? [{role: "system", content: system_message, timestamp: Time.current}] : []
          )
        end

        def schema_to_json(schema)
          schema.to_json_schema.to_json
        end

        def add_user_message(content)
          @chat.messages ||= []
          @chat.messages << {role: "user", content: content, timestamp: Time.current}
          @chat.save!
        end

        def update_chat_with_response(provider_response)
          # Add assistant response to messages
          @chat.messages ||= []
          @chat.messages << {
            role: "assistant",
            content: provider_response[:content],
            timestamp: Time.current
          }

          # Store the entire raw provider response with timestamp
          @chat.raw_responses ||= []
          @chat.raw_responses << provider_response.merge(timestamp: Time.current)

          @chat.save!
        end
      end
    end
  end
end
