# frozen_string_literal: true

module Services
  module Penalties
    # Dynamic penalties are computed from list fields and must never be attached
    # to a list (ListPenalty validates this). One legacy attachment predates the
    # validation; this finds those rows and, unless dry_run, destroys them.
    class DetachDynamic
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(dry_run:)
        attachments = ::ListPenalty.where(penalty_id: ::Penalty.dynamic.select(:id))
        ids = attachments.pluck(:id)
        attachments.destroy_all unless dry_run

        Result.new(success?: true, data: {list_penalty_ids: ids}, errors: [])
      end
    end
  end
end
