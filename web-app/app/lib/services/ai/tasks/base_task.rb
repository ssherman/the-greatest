module Services
  module Ai
    module Tasks
      class BaseTask
        include Services::Ai::Capable

        def initialize(parent:, provider: nil, model: nil)
          @parent = parent
          validate_parent!
          @provider = provider || create_provider_from_task
          @model = model || task_model || @provider.default_model
        end

        def call
          # Create the chat when we actually need it
          @chat = create_chat!

          # Add user message to chat
          add_user_message(user_prompt_with_fallbacks)

          # Get response from provider
          provider_response = @provider.send_message!(
            ai_chat: @chat,
            content: user_prompt_with_fallbacks,
            response_format: supports?(:json_mode) ? response_format : nil,
            schema: supports?(:json_schema) ? response_schema : nil
          )

          # Update chat with response data
          update_chat_with_response(provider_response)

          # Process and persist the result
          process_and_persist(provider_response)
        rescue => e
          Services::Ai::Result.new(success: false, error: e.message)
        end

        private

        attr_reader :parent, :provider, :chat

        # Override in subclasses
        # e.g., :openai
        def task_provider
          nil
        end

        # e.g., "gpt-4"
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

        def user_prompt_with_fallbacks
          user_prompt
        end

        def response_format
          nil
        end

        def response_schema
          nil
        end

        def temperature
          0.2
        end

        def process_and_persist(raw) = raw

        def create_provider_from_task
          case task_provider
          when :openai
            Services::Ai::Providers::OpenaiStrategy.new
          # when :anthropic
          #   Services::Ai::Providers::AnthropicStrategy.new
          # when :gemini
          #   Services::Ai::Providers::GeminiStrategy.new
          else
            raise ArgumentError, "Unknown provider: #{task_provider}"
          end
        end

        def validate!(raw_json)
          # All providers now use RubyLLM schema validation
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
            response_schema: response_schema&.new&.to_json_schema,
            messages: system_message ? [{role: "system", content: system_message, timestamp: Time.current}] : []
          )
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

          # Store raw response data
          @chat.raw_responses ||= []
          @chat.raw_responses << {
            provider_response_id: provider_response[:id],
            model: provider_response[:model],
            usage: provider_response[:usage],
            timestamp: Time.current
          }

          @chat.save!
        end
      end
    end
  end
end
