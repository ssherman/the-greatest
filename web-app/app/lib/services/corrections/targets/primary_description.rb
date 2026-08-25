module Services
  module Corrections
    module Targets
      # The record's displayed description.
      #
      # NOT a column. books_books.description is read by nothing and is scheduled
      # for deletion as the last step of the descriptions subsystem; the displayed
      # text comes from the polymorphic `descriptions` table, resolved by source
      # priority. This target earns its special case: 68 of the 448 legacy
      # changesets propose a description, the second-largest category.
      #
      # Named PrimaryDescription, not Description: a class named Description nested
      # inside this module would shadow the top-level ::Description model for every
      # constant lookup in this namespace.
      class PrimaryDescription
        def self.read(record, _field_name)
          record.primary_description&.content
        end

        # assign_description assigns onto the association without saving (the
        # association is autosave: true), and reuses the existing manual row rather
        # than adding a second -- the descriptions natural-key unique index would
        # reject one anyway.
        #
        # source: :manual is first in Descriptions::SourcePriority::ORDER, so an
        # applied correction outranks the Wikipedia or OpenLibrary text with no
        # rank change and no demote-then-promote dance.
        def self.write(record, _field_name, value)
          record.assign_description(source: :manual, content: value)
        end
      end
    end
  end
end
