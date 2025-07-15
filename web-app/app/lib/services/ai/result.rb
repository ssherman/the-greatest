module Services
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

      def ==(other)
        other.is_a?(self.class) &&
          success == other.success &&
          data == other.data &&
          error == other.error &&
          ai_chat == other.ai_chat
      end

      def to_s
        "#<#{self.class} success: #{success.inspect}, data: #{data.inspect}, error: #{error.inspect}, ai_chat: #{ai_chat.inspect}>"
      end
    end
  end
end
