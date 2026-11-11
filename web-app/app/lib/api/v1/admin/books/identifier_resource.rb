# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # An identifier row as an admin API client sees it, and the "who holds this
        # value" row the find endpoint (and, in a refusal, `also_held_by`) returns.
        # Key order here IS the order in config/api/v1/admin_openapi.yaml.
        # Root-anchor every ::Books:: reference.
        class IdentifierResource
          RECORD_TYPES = {
            "Books::Book" => "book", "Books::Edition" => "edition",
            "Books::Author" => "author", "Books::Series" => "series"
          }.freeze

          # Identifiers with their holders loaded (and an edition's book), ready for
          # either shape below.
          def self.preload(identifiers)
            rows = identifiers.to_a
            ::ActiveRecord::Associations::Preloader.new(records: rows, associations: :identifiable).call
            editions = rows.filter_map(&:identifiable).grep(::Books::Edition)
            ::ActiveRecord::Associations::Preloader.new(records: editions, associations: :book).call
            rows
          end

          # {record_type:, id:, label:, book:}: `id` is the holder's, `book` the
          # edition's book (nil for any other holder). nil when the holder is gone.
          def self.holder_row(identifier)
            holder = identifier.identifiable
            return nil unless holder

            {
              record_type: RECORD_TYPES.fetch(identifier.identifiable_type),
              id: holder.id,
              label: holder.respond_to?(:title) ? holder.title : holder.name,
              book: holder.is_a?(::Books::Edition) ? {id: holder.book_id, title: holder.book&.title} : nil
            }
          end

          def initialize(identifier)
            @identifier = identifier
          end

          def to_h
            {
              id: @identifier.id,
              identifier_type: @identifier.identifier_type,
              value: @identifier.value,
              source: @identifier.source,
              created_at: @identifier.created_at,
              edition: edition
            }
          end

          private

          def edition
            holder = @identifier.identifiable
            return nil unless holder.is_a?(::Books::Edition)

            {id: holder.id, title: holder.title, edition_type: holder.edition_type, publication_year: holder.publication_year}
          end
        end
      end
    end
  end
end
