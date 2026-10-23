module Services
  module Corrections
    module Targets
      # A record's alternate titles, which live in the alternate_titles table. The
      # column on the record is only a copy of the kept and review rows.
      class AlternateTitles
        def self.read(record, field_name)
          record.alternate_titles
        end

        # Writes the table rows now and assigns the column copy without saving.
        # The applier's transaction and its save! cover both, so a failed save
        # rolls the rows back. No user is available at this layer.
        def self.write(record, field_name, value)
          ::Services::AlternateTitles::Writer.replace(record: record, titles: Array(value), source: :correction)
        end

        # Clearing the list is a real correction: every title is marked removed.
        def self.accepts_blank?
          true
        end
      end
    end
  end
end
