# frozen_string_literal: true

module Services
  module Books
    module Origin
      # Accepts the disagreements a backfill reported: the judge found a
      # well-supported answer that differs from the country a book held. Accepting
      # replaces the held country with the proposed one. A book whose real
      # countries no longer equal what the run saw is skipped, so an admin's later
      # edit is never reverted. Dry run by default.
      class AcceptDisagreements
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(label: nil, enrichment_ids: nil, apply: false)
          new(label: label, enrichment_ids: enrichment_ids, apply: apply).call
        end

        def initialize(label: nil, enrichment_ids: nil, apply: false)
          @label = label
          @enrichment_ids = enrichment_ids
          @apply = apply
        end

        def call
          rows = Categorize::LatestRows.call(kind: Judge::KIND, label: @label)
            .where("enrichments.facts->'origin'->>'reason' = 'disagreement'")
            .where("enrichments.facts->>'accepted_at' IS NULL").order(:id)
          rows = rows.where(id: @enrichment_ids) if @enrichment_ids
          rows = rows.to_a
          books = ::Books::Book.where(id: rows.map(&:enrichable_id)).includes(:countries).index_by(&:id)

          candidates = rows.filter_map do |row|
            book = books[row.enrichable_id]
            next unless book && real_countries(book) == Array(row.facts.dig("origin", "held")).sort

            {enrichment_id: row.id, book_id: book.id, title: book.title,
             held: real_countries(book), proposed: row.facts.dig("origin", "country")}
          end

          accepted = @apply ? candidates.count { |candidate| accept(candidate) } : 0
          Result.new(success?: true, errors: [], data: {candidates: candidates, accepted: accepted})
        end

        private

        def real_countries(book)
          book.countries.map(&:name).reject { |name| CountryLookup::PLACEHOLDERS.include?(name.downcase) }.sort
        end

        def accept(candidate)
          country = CountryLookup.from_text([candidate[:proposed]]).countries.first
          return false unless country

          accepted = false
          ActiveRecord::Base.transaction do
            book = ::Books::Book.lock.find(candidate[:book_id])
            # Re-check under the lock: the dry-run read may be stale.
            next unless real_countries(book.tap { it.countries.reset }) == candidate[:held]

            book.book_countries.reload.each(&:destroy!)
            book.book_countries.create_or_find_by!(country: country)
            enrichment = ::Enrichment.find(candidate[:enrichment_id])
            enrichment.update!(facts: enrichment.facts.merge("accepted_at" => Time.current.iso8601))
            SearchIndexRequest.create!(parent: book, action: :index_item)
            accepted = true
          end
          accepted
        end
      end
    end
  end
end
