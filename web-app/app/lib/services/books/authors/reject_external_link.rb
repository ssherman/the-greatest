# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The Reject link action on the audit page (spec §12): a person says a
      # Wikidata or VIAF record is not this author. Rejected together: this
      # decision, every other decision of its finder that selected the same
      # record for the author, and, for a VIAF record, the Wikidata decisions
      # that matched the Wikidata id its run stamped. For each, what its run
      # applied is reverted (RevertFacts) and the record's own id and
      # Wikipedia link are removed, whoever added them. The AI runs that used
      # a rejected record are reverted too, and the AI description is
      # deprecated when one of them wrote it. The decisions are marked
      # rejected and reviewed, and the Wikidata step runs again, forced. No
      # step considers or stamps a rejected record again (RejectedRecords).
      class RejectExternalLink
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        OWN_IDENTIFIER = {"wikidata" => "books_author_wikidata_qid", "viaf" => "books_author_viaf"}.freeze
        OWN_IDENTIFIER_FACT = {"wikidata" => "wikidata_qid", "viaf" => "viaf"}.freeze
        AI_FACTS = %w[birth_year death_year gender countries].freeze

        def self.call(decision:, user:)
          new(decision: decision, user: user).call
        end

        def initialize(decision:, user:)
          @decision = decision
          @user = user
          @author = decision.subject
          @reverted = []
          @deprecated = 0
        end

        def call
          refusal = refusal_reason
          return refused(refusal) if refusal

          rejected = ::ActiveRecord::Base.transaction do
            decision.lock!
            next nil if decision.verdict_rejected?

            targets.tap { |list| reject_all(list) }
          end
          return refused("This link was already rejected.") if rejected.nil?

          ::Books::Authors::WikidataJob.perform_async(author.id, true)
          Result.new(success?: true,
            data: {decisions: rejected.map(&:first), reverted: @reverted.uniq, descriptions_deprecated: @deprecated}, errors: [])
        end

        private

        attr_reader :decision, :user, :author

        def refusal_reason
          return "Only a Wikidata or VIAF link decision can be rejected." unless RejectedRecords::FINDERS.key?(decision.finder)
          return "Only a decision that matched a record can be rejected." unless decision.matched? && key_of(decision).present?
          return "This link was already rejected." if decision.verdict_rejected?
          return "The author is gone." unless author.is_a?(::Books::Author)

          nil
        end

        def refused(message) = Result.new(success?: false, data: {}, errors: [message])

        # [[decision, source, key], ...], this decision first.
        def targets
          source = RejectedRecords::FINDERS.fetch(decision.finder)
          list = same_record(decision.finder, key_of(decision)).map { |target| [target, source, key_of(target)] }
          return list unless source == "viaf"

          follow_ups = list.flat_map do |target, _source, _key|
            stamped_qids(target).flat_map { |qid| same_record(ResolveWikidata.name, qid, since: target.created_at) }
          end
          list + follow_ups.uniq.map { |target| [target, "wikidata", key_of(target)] }
        end

        def same_record(finder, key, since: nil)
          scope = ::MatchDecision.where(subject: author, finder: finder, outcome: :matched)
          scope = scope.where(created_at: since..) if since
          found = scope.order(:created_at, :id).reject(&:verdict_rejected?).select { |target| key_of(target) == key }
          found.include?(decision) ? [decision] + (found - [decision]) : found
        end

        def stamped_qids(viaf_decision)
          ::Enrichment.where(match_decision: viaf_decision).filter_map do |row|
            fact = row.facts["wikidata_qid"]
            fact["value"] if fact.is_a?(Hash) && fact["applied"] == true
          end.uniq
        end

        def key_of(target) = target.selected_candidate&.dig("external_key").presence

        def reject_all(list)
          list.each { |target, source, key| revert_run(target, source, key) }
          influenced = influenced_ai_runs(list.map { |_target, source, key| {"source" => source, "source_id" => key} })
          influenced.each { |row| @reverted.concat(RevertFacts.call(author: author, facts: row.facts.slice(*AI_FACTS)).data[:reverted]) }
          deprecate_ai_description(influenced)
          list.each { |target, _source, _key| mark_rejected(target) }
        end

        def revert_run(target, source, key)
          ::Enrichment.where(match_decision: target).find_each do |row|
            @reverted.concat(RevertFacts.call(author: author, facts: row.facts).data[:reverted])
            wikipedia = row.facts["wikipedia"]
            remove_links(wikipedia["value"]) if source == "wikidata" && wikipedia.is_a?(Hash) && wikipedia["reason"] == "already_set"
          end
          identifiers = author.identifiers.where(identifier_type: OWN_IDENTIFIER.fetch(source), value: key).to_a
          identifiers.each(&:destroy!)
          @reverted << OWN_IDENTIFIER_FACT.fetch(source) if identifiers.any?
          author.identifiers.reset
        end

        # The item's article, linked before this run: it names the rejected record too.
        def remove_links(url)
          links = author.external_links.where(url: url.to_s).to_a
          links.each(&:destroy!)
          @reverted << "wikipedia" if links.any?
          author.external_links.reset
        end

        # The AI step's runs whose input included a rejected record (its
        # "sources" fact, spec §9).
        def influenced_ai_runs(records)
          author.enrichments.for_kind(EnrichAuthor::KIND).order(:created_at, :id).select do |row|
            Array(row.facts.dig("sources", "value")).intersect?(records)
          end
        end

        # The applier writes a description only over a missing or deprecated
        # one, so the latest run that applied a description wrote the
        # current text.
        def deprecate_ai_description(influenced)
          writer = author.enrichments.for_kind(EnrichAuthor::KIND).order(created_at: :desc, id: :desc)
            .find { |row| row.facts.dig("description", "applied") == true }
          return unless writer && influenced.include?(writer)

          author.descriptions.reload.select { |row| row.source == "ai_generated" && !row.deprecated? }.each do |row|
            row.update!(rank: :deprecated)
            @deprecated += 1
          end
        end

        def mark_rejected(target)
          target.update!(verdict: :rejected)
          target.review!(by: user, note: target.review_note.presence || "Link rejected.")
        end
      end
    end
  end
end
