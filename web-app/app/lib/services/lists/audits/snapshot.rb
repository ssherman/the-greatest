module Services
  module Lists
    module Audits
      # Captures the audit-relevant state of a list: its editable fields and its
      # attached penalties. Start stores one as "before", Finish one as "after".
      class Snapshot
        FIELDS = %w[
          name description source source_country_origin url year_published number_of_voters
          num_years_covered yearly_award high_quality_source category_specific location_specific
          creator_specific voter_count_estimated voter_count_unknown voter_names_unknown
          estimated_quality
        ].freeze

        def self.call(list)
          {
            "fields" => FIELDS.index_with { |field| list.public_send(field) },
            "penalties" => list.penalties.reorder(:id).map { |p| {"id" => p.id, "name" => p.name} }
          }
        end
      end
    end
  end
end
