# frozen_string_literal: true

module Services
  module Lists
    # Attaches and detaches a static penalty on a books list. Only the books
    # catalogue (Books::Penalty and Global::Penalty with no owner) can be
    # attached, and never a dynamic one: its value comes from a list field, so
    # the refusal names the field to set instead. Both calls are idempotent.
    class PenaltyLinks
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.attach(list:, penalty_id:)
        penalty = ::Penalty.books_catalogue.find_by(id: penalty_id)
        return failure("Penalty #{penalty_id} is not a books list penalty (see list_admin_penalties).") unless penalty
        return failure(dynamic_refusal(penalty)) if penalty.dynamic?
        return success(penalty: penalty, changed: false) if list.list_penalties.exists?(penalty_id: penalty.id)

        link = list.list_penalties.build(penalty: penalty)
        return failure(link.errors.full_messages) unless link.save

        success(penalty: penalty, changed: true)
      rescue ActiveRecord::RecordNotUnique
        success(penalty: penalty, changed: false)
      end

      def self.detach(list:, penalty_id:)
        removed = list.list_penalties.where(penalty_id: penalty_id).destroy_all
        success(changed: removed.any?)
      end

      def self.dynamic_refusal(penalty)
        field = penalty.driving_field
        return "Penalty #{penalty.id} is dynamic: it is computed from the list's books and never attached." unless field

        "Penalty #{penalty.id} is dynamic: set #{field} with update_admin_list instead."
      end
      private_class_method :dynamic_refusal

      def self.success(data) = Result.new(success?: true, data: data, errors: [])

      def self.failure(errors) = Result.new(success?: false, data: {}, errors: Array(errors))
      private_class_method :success, :failure
    end
  end
end
