# frozen_string_literal: true

module Services
  module Lists
    # The one save an admin makes on a list's editable fields (the admin API's
    # update_admin_list). FIELDS is the single definition of what is editable:
    # the audit snapshot and the admin list resource read it too, so a field
    # added here is audited and shown without a second edit. Never status or the
    # imported content (raw_content, simplified_content, items_json, wizard_state).
    #
    # attrs is partial: keys not in it are left alone. A nil value clears the
    # field; items_need_revision may be set true but never cleared here (an
    # admin clears it in the admin UI, which does not go through this service);
    # estimated_quality is NOT NULL, so clearing it stores its column
    # default of 0. Model validation messages are the errors, and nothing is
    # written when the save fails.
    class AdminUpdate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      CLEAR_REFUSAL = "items_need_revision cannot be set back to false here: only an admin clears this flag in the admin UI."

      FIELDS = %w[
        name description voter_details items_need_revision source source_country_origin url year_published number_of_voters
        num_years_covered yearly_award high_quality_source category_specific location_specific
        creator_specific voter_count_estimated voter_count_unknown voter_names_unknown
        estimated_quality
      ].freeze

      def self.call(list:, attrs:, user:, via:, explicit_nulls: [])
        attrs = attrs.to_h.stringify_keys.slice(*FIELDS)
        if attrs["items_need_revision"] == false && list.items_need_revision
          return Result.new(success?: false, data: {}, errors: [CLEAR_REFUSAL])
        end
        attrs["estimated_quality"] = 0 if attrs.key?("estimated_quality") && attrs["estimated_quality"].nil?
        before = attrs.keys.index_with { |key| list.public_send(key) }

        list.assign_attributes(attrs)
        return Result.new(success?: false, data: {}, errors: list.errors.full_messages) unless list.save

        changed = before.keys.reject { |key| before[key] == list.public_send(key) }
        Result.new(success?: true, data: {changed: changed}, errors: [])
      end
    end
  end
end
