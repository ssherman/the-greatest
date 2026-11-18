module Services
  module UserLists
    class BatchFailed < StandardError
      attr_reader :errors

      def initialize(errors)
        @errors = Array(errors)
        super(@errors.to_sentence)
      end
    end
  end
end
