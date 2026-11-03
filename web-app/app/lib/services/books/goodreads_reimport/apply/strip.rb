# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      module Apply
        # Applies a reimport_strip verdict (re-import spec 4.7): a legacy identifier that a Goodreads edition
        # contradicts comes off the book. Only a legacy-sourced identifier is ever removed; one an importer or a
        # person attached since is left alone. What was removed is kept in the payload (`removed`).
        class Strip
          def self.call(verdict:)
            return Entries.noop("already applied") if verdict.applied_at.present?
            return Entries.noop("verdict is not approved and current") unless verdict.approved? && verdict.superseded_at.nil?

            payload = verdict.payload
            book = GoodreadsReplay::Apply::MergedBook.call(payload["book_id"])
            return Entries.noop("book #{payload["book_id"]} no longer exists", final: true) unless book

            identifiers = book.identifiers.where(identifier_type: payload["identifier_type"], value: payload["value"]).to_a
            return Entries.noop("identifier already gone", final: true) if identifiers.empty?
            # The removal below is by type and value; a mixed set would drag a non-legacy one with it.
            return Entries.noop("identifier is not a legacy one", final: true) unless identifiers.all? { |identifier| identifier.source == "legacy" }

            ::Identifier.transaction do
              removed = identifiers.map { |identifier| identifier.attributes.slice("id", "identifiable_id", "identifier_type", "value", "source", "created_at") }
              verdict.update_columns(payload: payload.merge("removed" => removed))
              GoodreadsReplay::Apply::StripIdentifier.change(book: book, remove: [[payload["identifier_type"], payload["value"]]], add: [])
            end
            Entries.applied
          end
        end
      end
    end
  end
end
