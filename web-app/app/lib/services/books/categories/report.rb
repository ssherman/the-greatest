# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Summarises the books.categories ledger rows of a run for the owner: what
      # was added, confirmed, removed and held back, the type conflicts, the
      # names the vocabulary could not match, and genre names worth aliasing.
      # Counts the newest row per book only.
      class Report
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        UNMATCHED_LIMIT = 20
        UNLISTED_LIMIT = 30
        CONFLICT_LIMIT = 50

        def self.call(label: nil)
          new(label: label).call
        end

        def initialize(label: nil)
          @label = label
        end

        def call
          latest = Categorize::LatestRows.call(kind: Judge::KIND, label: @label)
          rows = latest.order(:enrichable_id).pluck(
            Arel.sql("enrichments.enrichable_id"), Arel.sql("enrichments.facts->'apply'"),
            Arel.sql("enrichments.facts->'mapping'->'unmatched'"), Arel.sql("enrichments.facts->'answer'->'unlisted_genres'"),
            Arel.sql("enrichments.facts->'dossier'->'wikidata'->'genres'"), Arel.sql("enrichments.facts->>'deferred_research'")
          )
          research = ::Enrichment.research.where(kind: Judge::KIND)
          research = research.where("facts->>'label' = ?", @label) if @label
          research_rows = research.count
          books = rows.size

          added = Hash.new(0)
          confirmed = Hash.new(0)
          removed = Hash.new(0)
          held_back = Hash.new(0)
          type_reasons = Hash.new(0)
          unmatched = Hash.new { |hash, key| hash[key] = Hash.new(0) }
          unlisted = Hash.new(0)
          conflicts = []
          deferred = 0
          matcher = ::Services::Books::GoodreadsEnrichment::GenreMatcher.new
          resolvable = {}

          rows.each do |book_id, apply, unmatched_rows, unlisted_names, wikidata_genres, deferred_flag|
            apply ||= {}
            tally(added, apply["added"], "type")
            tally(confirmed, apply["confirmed"], "type")
            tally(removed, apply["removed"], "type")
            tally(held_back, apply["held_back"], "reason")
            type = apply["type"] || {}
            type_reasons[type["reason"]] += 1 if type["reason"]
            if type["reason"] == "type_conflict"
              conflicts << {book_id: book_id, judged: type["judged"], held: type["held"]}
            end
            Array(unmatched_rows).each do |entry|
              proposed = entry["proposed"].to_s.strip.downcase
              unmatched[entry["type"]][proposed] += 1 if proposed.present?
            end
            names = Array(unlisted_names).map { fold(it) }
            Array(wikidata_genres).each do |label|
              folded = fold(label)
              next if folded.blank?
              resolvable[folded] = matcher.match(label).present? unless resolvable.key?(folded)
              names << folded unless resolvable[folded]
            end
            names.reject(&:blank?).uniq.each { unlisted[it] += 1 }
            deferred += 1 if deferred_flag == "true"
          end

          titles = ::Books::Book.where(id: conflicts.first(CONFLICT_LIMIT).map { it[:book_id] }).pluck(:id, :title).to_h
          type_conflicts = conflicts.first(CONFLICT_LIMIT).map { it.merge(title: titles[it[:book_id]]) }
            .map { it.slice(:book_id, :title, :judged, :held) }

          Result.new(success?: true, errors: [], data: {
            books: books,
            by_outcome: latest.group(:outcome).count.transform_keys { |key| ::Enrichment.outcomes.key(key) || key.to_s },
            added: added, confirmed: confirmed, removed: removed, held_back: held_back, type: type_reasons,
            type_conflicts: type_conflicts,
            unmatched: unmatched.transform_values { |counts| top(counts, UNMATCHED_LIMIT) },
            unlisted_genres: top(unlisted, UNLISTED_LIMIT),
            research_rows: research_rows,
            research_cost_estimate: research_rows * Origin::Report::RESEARCH_COST_PER_ROW,
            deferred_research: deferred,
            avg_added_per_book: average(added, books),
            avg_removed_per_book: average(removed, books)
          })
        end

        private

        def tally(counts, entries, key)
          Array(entries).each { |entry| counts[entry[key]] += 1 if entry[key] }
        end

        def fold(name)
          name.to_s.strip.downcase
        end

        def top(counts, limit)
          counts.sort_by { |name, count| [-count, name] }.first(limit)
        end

        def average(counts, books)
          (books == 0) ? 0.0 : counts.values.sum.fdiv(books).round(2)
        end
      end
    end
  end
end
