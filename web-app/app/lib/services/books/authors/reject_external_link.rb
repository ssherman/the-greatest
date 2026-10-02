# frozen_string_literal: true

module Services
  module Books
    module Authors
      # The Reject link action on the audit page (spec §12): a person says a
      # Wikidata or VIAF record is not this author. A reject bans the person,
      # not only the one record, so it runs both ways (increment 5 Group A).
      # Rejected together: this decision, every other decision of its finder
      # that selected the same record for the author, and, for a VIAF
      # record, every Wikidata decision that matched the Wikidata id its run
      # stamped -- directly, or through a Wikidata redirect the ledger
      # recorded as `redirected_from` -- regardless of when that decision was
      # recorded. The other way: rejecting a Wikidata decision also rejects
      # every VIAF decision whose cluster names that Wikidata id as its own
      # link, one hop, never chased further. For each, what its run applied
      # is reverted (RevertFacts, only this author's own era -- Group B) and
      # the record's own id and Wikipedia link are removed, whoever added
      # them; a superseded id a Wikidata merge run kept held alongside the
      # canonical one goes too.
      # The AI runs that used a rejected record are reverted too, and the AI
      # description is deprecated when one of them wrote it. The decisions
      # are marked rejected and reviewed, and the Wikidata step runs again,
      # forced. No step considers or stamps a rejected record again
      # (RejectedRecords), and MatchedRecords ignores a rejected decision, so
      # no rejected evidence reaches the AI step.
      class RejectExternalLink
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        OWN_IDENTIFIER = {"wikidata" => "books_author_wikidata_qid", "viaf" => "books_author_viaf"}.freeze
        OWN_IDENTIFIER_FACT = {"wikidata" => "wikidata_qid", "viaf" => "viaf"}.freeze
        AI_FACTS = %w[birth_year death_year gender countries].freeze
        # Seconds before the re-run may start; the transaction that queues
        # it commits long before.
        RERUN_DELAY = 10

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

            list = targets.tap { |found| reject_all(found) }
            # Queued inside the transaction, last, so a push that fails
            # rolls the whole reject back and a retry can go through: a
            # reject committed without its re-run would leave the author
            # stripped, and a retry is refused as already rejected. The
            # delay keeps the job from starting before this commits.
            ::Books::Authors::WikidataJob.perform_in(RERUN_DELAY, author.id, true)
            list
          end
          return refused("This link was already rejected.") if rejected.nil?

          Result.new(success?: true,
            data: {decisions: rejected.map(&:first), reverted: @reverted.uniq, descriptions_deprecated: @deprecated}, errors: [])
        rescue ::RedisClient::Error => e
          refused("The author's re-run could not be queued (#{e.class.name.demodulize}), so nothing was changed. Try again.")
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
          if source == "viaf"
            list = same_record(decision.finder, key_of(decision)).map { |target| [target, source, key_of(target)] }
            qids = list.flat_map { |target, _source, _key| stamped_qids(target) }.uniq
            wikidata_decisions, = wikidata_decisions_for(qids)
            return list + wikidata_decisions.map { |target| [target, "wikidata", key_of(target)] }
          end

          ids = ([key_of(decision)] + redirected_from(decision)).compact.uniq
          wikidata_decisions, wikidata_ids = wikidata_decisions_for(ids)
          wikidata_targets = pin_first(wikidata_decisions, decision).map { |target| [target, source, key_of(target)] }
          wikidata_targets + viaf_decisions_linked_to(wikidata_ids).map { |target| [target, "viaf", key_of(target)] }
        end

        # A VIAF cluster whose own Wikidata link is one of these rejected
        # Wikidata ids is the same rejected person (Group A): the cascade
        # runs one hop, Wikidata to VIAF, matching on the candidate's own
        # evidence rather than a ledger row, since the link is VIAF's own
        # record of the person, not something ApplyViaf stamped. No further
        # recursion from here -- a VIAF decision swept in this way does not
        # itself pull in more Wikidata decisions.
        def viaf_decisions_linked_to(ids)
          return [] if ids.empty?

          ::MatchDecision.where(subject: author, finder: ResolveViaf.name, outcome: :matched)
            .order(:created_at, :id).reject(&:verdict_rejected?)
            .select { |target| ids.include?(target.selected_candidate&.dig("evidence", "wikidata_qid")) }
        end

        def same_record(finder, key)
          scope = ::MatchDecision.where(subject: author, finder: finder, outcome: :matched)
          found = scope.order(:created_at, :id).reject(&:verdict_rejected?).select { |target| key_of(target) == key }
          pin_first(found, decision)
        end

        def pin_first(list, item)
          list.include?(item) ? [item] + (list - [item]) : list
        end

        def stamped_qids(viaf_decision)
          ::Enrichment.where(match_decision: viaf_decision).filter_map do |row|
            fact = row.facts["wikidata_qid"]
            fact["value"] if fact.is_a?(Hash) && fact["applied"] == true
          end.uniq
        end

        # Every unrejected, matched Wikidata decision that is the same record
        # as one of `ids`: its own key is one of them, or -- one hop, never
        # chased further -- its own ledger rows name one of them as
        # `redirected_from`. A key reached this way is folded into the set
        # before the final match, so a cascaded follow-up's own plain
        # siblings (another decision sharing its exact key, with no redirect
        # of its own) are swept in too -- the same "same key" rule decision 1
        # already applies to the decision being rejected directly.
        #
        # Returns `[decisions, ids]`: the swept decisions, and the full
        # Wikidata id set they ultimately stand for -- each one's own key
        # plus its own entries in the `redirects` map already loaded here.
        # That second value is the FINAL target set a Wikidata->VIAF cascade
        # has to match against, which can be wider than the `ids` this method
        # was called with once the sweep reaches a sibling through its own
        # redirect.
        def wikidata_decisions_for(ids)
          return [[], []] if ids.empty?

          pool = ::MatchDecision.where(subject: author, finder: ResolveWikidata.name, outcome: :matched)
            .order(:created_at, :id).reject(&:verdict_rejected?)
          redirects = redirects_by_decision(pool)
          # Seed the id set with the redirects of every pool decision whose
          # own key is already in it, before matching: a sibling sharing the
          # key being rejected can itself carry a `redirected_from` onto an
          # older, pre-merge decision, and that older decision has to be
          # reached too, not just the sibling.
          seeded = pool.select { |target| ids.include?(key_of(target)) }.flat_map { |target| redirects.fetch(target.id, []) }
          ids = (ids + seeded).uniq
          reached = pool.select { |target| redirects.fetch(target.id, []).intersect?(ids) }.map { |target| key_of(target) }
          expanded = (ids + reached).compact.uniq
          decisions = pool.select { |target| expanded.include?(key_of(target)) || redirects.fetch(target.id, []).intersect?(ids) }
          final_ids = decisions.flat_map { |target| [key_of(target)] + redirects.fetch(target.id, []) }.compact.uniq
          [decisions, final_ids]
        end

        # {decision_id => ["Q9", ...]}, one query for every decision in `pool`.
        def redirects_by_decision(pool)
          return {} if pool.empty?

          ::Enrichment.where(match_decision_id: pool.map(&:id))
            .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |row, map|
              map[row.match_decision_id].concat(wikidata_qid_redirects(row))
            end
        end

        def redirected_from(target)
          ::Enrichment.where(match_decision: target).flat_map { |row| wikidata_qid_redirects(row) }.uniq
        end

        def wikidata_qid_redirects(row)
          fact = row.facts["wikidata_qid"]
          fact.is_a?(Hash) ? Array(fact["redirected_from"]) : []
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
          redirected = []
          ::Enrichment.where(match_decision: target).find_each do |row|
            redirected.concat(wikidata_qid_redirects(row)) if source == "wikidata"
            # Spec §14: a pre-migration ledger row survives truncation and
            # points at a re-created author with the same id. Only a row from
            # this author's own era gets reverted -- the record's own id (and
            # any redirected ids gathered above) is removed regardless of
            # age, since it names the rejected record itself, not something
            # that era applied.
            next unless row.created_at > author.created_at

            @reverted.concat(RevertFacts.call(author: author, facts: row.facts).data[:reverted])
            wikipedia = row.facts["wikipedia"]
            remove_links(wikipedia["value"]) if source == "wikidata" && wikipedia.is_a?(Hash) && wikipedia["reason"] == "already_set"
          end
          values = ([key] + redirected).compact.uniq
          identifiers = author.identifiers.where(identifier_type: OWN_IDENTIFIER.fetch(source), value: values).to_a
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
        # "sources" fact, spec §9), restricted to this author's own era
        # (spec §14, Group B): a pre-migration run's values are not this
        # author's to revert.
        def influenced_ai_runs(records)
          author.enrichments.for_kind(EnrichAuthor::KIND).where("enrichments.created_at > ?", author.created_at)
            .order(:created_at, :id).select do |row|
            Array(row.facts.dig("sources", "value")).intersect?(records)
          end
        end

        # The applier writes a description only over a missing or deprecated
        # one, so the latest run that applied a description wrote the
        # current text.
        def deprecate_ai_description(influenced)
          writer = author.enrichments.for_kind(EnrichAuthor::KIND).where("enrichments.created_at > ?", author.created_at)
            .order(created_at: :desc, id: :desc).find { |row| row.facts.dig("description", "applied") == true }
          return unless writer && influenced.include?(writer)

          author.descriptions.reload.select { |row| row.source == "ai_generated" && !row.deprecated? }.each do |row|
            row.update!(rank: :deprecated)
            @deprecated += 1
          end
        end

        def mark_rejected(target)
          target.update!(verdict: :rejected)
          note = "Link rejected."
          note += " Earlier note: #{target.review_note}" if target.review_note.present?
          target.review!(by: user, note: note)
        end
      end
    end
  end
end
