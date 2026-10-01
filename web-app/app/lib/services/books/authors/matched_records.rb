# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The records the author steps matched this author to, as the AI step's
      # evidence (spec §9): the Wikidata item, its English Wikipedia lead,
      # and the VIAF cluster. Each comes from the latest processed ledger row
      # of its step, newer than the author row, and from the candidate that
      # row's decision selected, whose snapshot already carries labelled
      # evidence. A row whose decision matched nothing, or whose held id
      # conflicted with the match (nothing was applied), contributes nothing.
      # Identifiers alone are not used: an id is what a source calls the
      # author, and only a decision says the record is this author.
      class MatchedRecords
        Match = Struct.new(:source_id, :evidence, keyword_init: true)

        # The same "done" outcomes for both steps.
        PROCESSED = EnrichFromWikidata::PROCESSED
        CONFLICTS = {
          EnrichFromWikidata::KIND => "held_qid_conflict",
          EnrichFromViaf::KIND => "held_viaf_conflict"
        }.freeze

        def initialize(author)
          @author = author
          @rows = {}
          @matches = {}
        end

        def wikidata = match(EnrichFromWikidata::KIND)

        def viaf = match(EnrichFromViaf::KIND)

        def matched? = wikidata.present? || viaf.present?

        # The lead of the article the matched Wikidata run linked. The link
        # step stores only a page that names the same item back and is not a
        # disambiguation page; the item is compared again here in case the
        # stored page was refreshed since.
        def lead
          return @lead if defined?(@lead)

          page = wikidata && row(EnrichFromWikidata::KIND).facts.dig("wikipedia", "page")
          record = page && ::ExternalRecord.find_by(source: :wikipedia, source_id: page)
          found = record && ::Wikipedia::Lead.from_payload(record.payload)
          @lead = (found if found && found.wikibase_item == wikidata.source_id)
        end

        # What went into the AI step's input, for its ledger row (spec §9, §12).
        def sources
          list = []
          list << {"source" => "wikidata", "source_id" => wikidata.source_id} if wikidata
          list << {"source" => "wikipedia", "source_id" => lead.source_id} if lead
          list << {"source" => "viaf", "source_id" => viaf.source_id} if viaf
          list
        end

        private

        attr_reader :author

        def match(kind)
          return @matches[kind] if @matches.key?(kind)

          latest = row(kind)
          decision = latest&.match_decision
          candidate = decision&.matched? && decision.selected_index && Array(decision.candidates)[decision.selected_index - 1]
          @matches[kind] = if candidate && latest.reason != CONFLICTS.fetch(kind)
            Match.new(source_id: candidate["external_key"], evidence: candidate["evidence"].to_h)
          end
        end

        def row(kind)
          return @rows[kind] if @rows.key?(kind)

          @rows[kind] = author.enrichments.for_kind(kind).where(outcome: PROCESSED)
            .where("enrichments.created_at > ?", author.created_at)
            .includes(:match_decision).order(created_at: :desc, id: :desc).first
        end
      end
    end
  end
end
