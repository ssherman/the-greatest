module Services
  module UserLists
    MutationResult = Struct.new(:success?, :data, :errors, keyword_init: true)

    class << MutationResult
      def failure(errors)
        new(success?: false, data: nil, errors: errors)
      end

      def stale_item
        failure(["Item no longer exists"])
      end

      def aborted_mutation(error)
        errors = error.record.errors.full_messages if error.record.respond_to?(:errors)
        failure(errors.presence || ["Mutation could not be completed"])
      end

      def record_invalid(error)
        errors = error.record.errors.full_messages
        failure(errors.presence || [error.message])
      end
    end
  end
end
