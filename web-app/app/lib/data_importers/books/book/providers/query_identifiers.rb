# frozen_string_literal: true

module DataImporters
  module Books
    module Book
      module Providers
        # Stamps the query's own identifiers on the book whatever Open Library
        # said (Goodreads import spec §5). Providers::OpenLibrary stamps them
        # only on an accept, so a book created while the service is down or
        # abstaining could never be found again by the identifier it came in
        # with. Runs only when the importer is asked to (stamp_identifiers).
        class QueryIdentifiers < DataImporters::ProviderBase
          def populate(book, query:, match: nil)
            return success_result(data_populated: []) if query.nil?

            stamped = []
            Providers::OpenLibrary::IDENTIFIER_TYPE_BY_QUERY_FIELD.each do |field, identifier_type|
              Array(query.public_send(field)).each do |value|
                identifier = book.identifiers.find_or_initialize_by(identifier_type: identifier_type, value: value)
                stamped << identifier_type.to_s if identifier.new_record?
              end
            end
            success_result(data_populated: stamped.uniq)
          end
        end
      end
    end
  end
end
