module Services
  module Ai
    module ProviderStrategy
      # Required: sends message to provider and returns structured response
      def send_message!(ai_chat:, content:, response_format:, schema:)
      end

      # Required: returns array of supported capabilities
      def capabilities
      end

      # Required: returns default model for this provider
      def default_model
      end

      # Required: returns provider key for enum mapping
      def provider_key
      end
    end
  end
end
