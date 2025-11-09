module Actions
  module Admin
    class BaseAction
      attr_reader :user, :models, :fields

      class ActionResult
        attr_reader :status, :message, :data

        def initialize(status:, message:, data: nil)
          @status = status
          @message = message
          @data = data
        end

        def success?
          status == :success
        end

        def error?
          status == :error
        end

        def warning?
          status == :warning
        end
      end

      def self.call(user:, models:, fields: {})
        new(user: user, models: models, fields: fields).call
      end

      def initialize(user:, models:, fields: {})
        @user = user
        @models = Array(models)
        @fields = fields
      end

      def call
        raise NotImplementedError, "Subclasses must implement #call"
      end

      # Override in subclasses to define action metadata
      def self.name
        raise NotImplementedError
      end

      def self.message
        ""
      end

      def self.confirm_button_label
        "Confirm"
      end

      def self.visible?(context = {})
        true
      end

      protected

      def succeed(message, data: nil)
        ActionResult.new(status: :success, message: message, data: data)
      end

      def error(message, data: nil)
        ActionResult.new(status: :error, message: message, data: data)
      end

      def warn(message, data: nil)
        ActionResult.new(status: :warning, message: message, data: data)
      end
    end
  end
end
