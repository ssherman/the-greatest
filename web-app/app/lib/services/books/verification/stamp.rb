# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 2, stage 2's table: one identifier a verified source ties
      # to the book. Writes or confirms it and records the finding. Never
      # touches another book's row. Callers run it inside their stage's
      # transaction.
      module Stamp
        module_function

        def call(verification:, type:, value:, source:, evidence: {})
          book = verification.book
          held = book.identifiers.find_by(identifier_type: type, value: value)
          if held
            return :unchanged if held.source.in?(::Identifier::VERIFIED_SOURCES)

            confirm(verification: verification, identifier: held, source: source, evidence: evidence)
            return :confirmed
          end

          others = ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value).where.not(identifiable_id: book.id)
          if (verified_holder = others.verified.order(:identifiable_id).pick(:identifiable_id))
            finding(verification, :conflict, type, value, other_book_id: verified_holder, evidence: evidence)
            return :conflict
          end

          holders = others.order(:identifiable_id).pluck(:identifiable_id)
          identifier = book.identifiers.create!(identifier_type: type, value: value, source: source)
          finding(verification, :added, type, value, identifier_id: identifier.id, source: source, evidence: evidence)
          if holders.any?
            finding(verification, :also_held, type, value, other_book_id: holders.first, evidence: evidence.merge("holders" => holders))
          end
          :added
        end

        def confirm(verification:, identifier:, source:, evidence: {})
          previous = identifier.source
          identifier.update!(source: source)
          finding(verification, :confirmed, identifier.identifier_type, identifier.value,
            identifier_id: identifier.id, source: source, previous_source: previous, evidence: evidence)
        end

        def finding(verification, kind, type, value, **attributes)
          row = ::Books::VerificationFinding.find_or_initialize_by(verification: verification, kind: kind, identifier_type: type, value: value)
          row.assign_attributes(book_id: verification.book_id, **attributes)
          row.save!
          row
        end
      end
    end
  end
end
