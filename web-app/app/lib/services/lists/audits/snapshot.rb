module Services
  module Lists
    module Audits
      # Captures the audit-relevant state of a list: its editable fields and its
      # attached penalties. Start stores one as "before", Finish one as "after".
      class Snapshot
        FIELDS = Services::Lists::AdminUpdate::FIELDS

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
