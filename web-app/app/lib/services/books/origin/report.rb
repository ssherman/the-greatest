# frozen_string_literal: true

module Services
  module Books
    module Origin
      # Summarises the books.origin ledger rows of a backfill run for the owner:
      # what was decided, which countries were written, the disagreements waiting
      # for a decision and the answers CountryLookup could not match.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        RESEARCH_COST_PER_ROW = 0.15
        REASON = "enrichments.facts->'origin'->>'reason'"
        COUNTRY = "enrichments.facts->'origin'->>'country'"
        RAW = "enrichments.facts->'origin'->>'raw'"

        # The newest books.origin row per book (highest id), optionally within
        # one run label. Shared with AcceptDisagreements.
        def self.latest_rows(label: nil)
          scope = ::Enrichment.where(kind: Judge::KIND)
          newer = "SELECT 1 FROM enrichments newer WHERE newer.enrichable_type = enrichments.enrichable_type " \
            "AND newer.enrichable_id = enrichments.enrichable_id AND newer.kind = enrichments.kind " \
            "AND newer.id > enrichments.id"
          if label
            scope = scope.where("enrichments.facts->>'label' = ?", label)
            newer += " AND newer.facts->>'label' = #{::Enrichment.connection.quote(label)}"
          end
          scope.where("NOT EXISTS (#{newer})")
        end

        def self.call(label: nil)
          new(label: label).call
        end

        def initialize(label: nil)
          @label = label
        end

        def call
          latest = self.class.latest_rows(label: @label)
          research = ::Enrichment.research.where(kind: Judge::KIND)
          research = research.where("facts->>'label' = ?", @label) if @label
          research_rows = research.count

          Result.new(success?: true, errors: [], data: {
            books: latest.count,
            by_path: latest.group("enrichments.facts->>'path'").count.compact,
            by_reason: latest.group(REASON).count.transform_keys { |reason| reason || "none" },
            applied_countries: top(latest.applied, COUNTRY, 15),
            disagreements: disagreements(latest),
            no_match: top(latest.where("#{REASON} = 'no_match'"), RAW, 20),
            research_rows: research_rows,
            research_cost_estimate: research_rows * RESEARCH_COST_PER_ROW,
            deferred_research: latest.where("enrichments.facts->>'deferred_research' = 'true'").count
          })
        end

        private

        def top(scope, expression, limit)
          scope.where("#{expression} IS NOT NULL").group(expression)
            .order(Arel.sql("COUNT(*) DESC, #{expression}")).limit(limit).count.to_a
        end

        def disagreements(latest)
          rows = latest.where("#{REASON} = 'disagreement'").order(:id).to_a
          titles = ::Books::Book.where(id: rows.map(&:enrichable_id)).pluck(:id, :title).to_h
          rows.map do |row|
            origin = row.facts["origin"] || {}
            {enrichment_id: row.id, book_id: row.enrichable_id, title: titles[row.enrichable_id],
             held: Array(origin["held"]), proposed: origin["country"],
             accepted_at: row.facts["accepted_at"]}
          end
        end
      end
    end
  end
end
