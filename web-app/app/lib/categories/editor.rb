# frozen_string_literal: true

module Categories
  # Assigns attributes to a category (new or persisted) and saves it. A location
  # moved to a new parent, or retyped into or out of location, changes the
  # inherited links of every book under it; the whole-catalog reconcile takes
  # seconds in production, so it runs in the background.
  class Editor
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    def self.call(category:, attributes:)
      category.assign_attributes(attributes)
      return Result.new(success?: false, data: category, errors: category.errors.full_messages) unless category.save

      ::Categories::ReconcileAncestorsJob.perform_async if reconcile_needed?(category)
      Result.new(success?: true, data: category, errors: [])
    end

    def self.reconcile_needed?(category)
      (category.saved_change_to_parent_id? || category.saved_change_to_category_type?) &&
        (category.location? || category.category_type_before_last_save == "location")
    end
    private_class_method :reconcile_needed?
  end
end
