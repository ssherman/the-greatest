# frozen_string_literal: true

module Services
  module UserLists
    # Creates a custom list. Does not take the owner lock: callers that add
    # books to it hold OwnerMutation themselves.
    class CreateList
      def self.call(user:, klass:, name:, description: nil, public: false)
        clean_name = ListRules.normalize_name(name)
        return MutationResult.failure(["name must be a string of 1 to #{ListRules::NAME_MAX} characters"]) if clean_name.nil?

        clean_description = ListRules.normalize_description(description)
        if clean_description == :invalid
          return MutationResult.failure(["description must be a string of up to #{ListRules::DESCRIPTION_MAX} characters, or null"])
        end

        list = klass.create!(user: user, name: clean_name, description: clean_description, public: public, list_type: :custom)
        MutationResult.new(success?: true, data: {list: list}, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        MutationResult.record_invalid(e)
      end
    end
  end
end
