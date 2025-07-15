module Services
  module Ai
    module Providers
      class BaseStrategy
        include Services::Ai::ProviderStrategy

        def send_message!(ai_chat:, content:, response_format:, schema:)
          messages = ai_chat.messages + [{role: "user", content: content}]

          parameters = build_parameters(
            model: ai_chat.model,
            messages: messages,
            temperature: ai_chat.temperature.to_f,
            response_format: response_format,
            schema: schema
          )

          response = make_api_call(parameters)

          # Return structured response wrapper
          format_response(response, schema)
        end

        protected

        # Abstract method - must be implemented by subclasses
        def client
          raise NotImplementedError, "Subclasses must implement #client"
        end

        # Abstract method - must be implemented by subclasses
        def make_api_call(parameters)
          raise NotImplementedError, "Subclasses must implement #make_api_call"
        end

        # Abstract method - must be implemented by subclasses
        def format_response(response, schema)
          raise NotImplementedError, "Subclasses must implement #format_response"
        end

        # Can be overridden by subclasses for provider-specific parameter building
        def build_parameters(model:, messages:, temperature:, response_format:, schema:)
          {
            model: model,
            messages: messages,
            temperature: temperature
          }
        end

        # Common response parsing logic
        def parse_response(content, schema)
          # Handle nil or empty content
          return {} if content.nil? || content.empty?

          # Parse JSON - providers should return valid structured data
          JSON.parse(content, symbolize_names: true)
        end
      end
    end
  end
end
