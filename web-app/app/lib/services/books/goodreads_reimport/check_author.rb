# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Checks one book's credited authors against what the CSV rows that now sit on it say (re-import spec 4.7),
      # and records a reimport_author verdict when they disagree. Run after the rows are on their exact books.
      #
      # The rows' names are the PRIMARY author of each of the book's editions (EditionFacts#primary_author), most
      # common first. Goodreads' additional authors are often translators and illustrators, so they are never
      # required: one joins the verdict only when the AI confirms it is among the book's current authors.
      #
      # Agree: every name matches a current author by name key (MatchAuthors settles those without the AI) or by
      # the AI's same-person check. Disagree: each unmatched name is looked up in the whole catalog with the author
      # finder and accepted only on a high-confidence match, else it is left nil (apply creates it). The verdict is
      # auto-approved only on an import-made book where every name was settled with confidence; a trusted book's
      # verdict is always a proposal.
      class CheckAuthor
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        ACCEPTED = %i[high certain].freeze

        def self.call(book:, author_finder: nil, task_class: ::Services::Ai::Tasks::Books::MatchExportAuthorsTask)
          new(book: book, author_finder: author_finder, task_class: task_class).call
        end

        # Trusted means a person put the book on a list by hand (Cohort). A book this run created is import-made
        # whatever its id: it was made after the post-import range was fixed, so Cohort would call it trusted.
        def self.trusted?(book_id)
          ::Services::Books::GoodreadsRebuild::Cohort.trusted?(book_id) &&
            !::Books::RepairVerdict.reimport_match.where("payload->>'created_book_id' = ?", book_id.to_s).exists?
        end

        # Names on `author.alternate_names` that are another existing author's name and that no row of this
        # author's books names. They were put there by a merge or an import that confused two people.
        def self.stale_alternates(author)
          alternates = Array(author.alternate_names).compact_blank
          return [] if alternates.empty?

          row_keys = row_names(author.book_authors.pluck(:book_id)).filter_map { |name| ::Services::Text::PersonNameKey.call(name) }
          alternates.select do |name|
            key = ::Services::Text::PersonNameKey.call(name)
            next false if key.nil? || row_keys.include?(key)

            ::Books::Author.where.not(id: author.id).where("books_authors.name_keys && ARRAY[?]::varchar[]", [key])
              .any? { |other| ::Services::Text::PersonNameKey.call(other.name) == key }
          end
        end

        # Every name the CSV rows of these books' editions carry.
        def self.row_names(book_ids)
          ::Books::GoodreadsEdition.where(id: edition_ids(book_ids)).pluck(:primary_author, :additional_authors).flatten.compact_blank
        end

        def self.edition_ids(book_ids)
          ::Books::RepairVerdict.reimport_row.current.where.not(applied_at: nil)
            .where("payload ->> 'to_book_id' IN (?)", Array(book_ids).map(&:to_s))
            .pluck(Arel.sql("payload ->> 'goodreads_edition_id'")).compact.map(&:to_i).uniq
        end

        def initialize(book:, author_finder:, task_class:)
          @book = book
          @author_finder = author_finder
          @task_class = task_class
        end

        def call
          # An applied verdict is final: its payload holds what undoing it needs.
          return done(:kept, current_verdict) if current_verdict&.applied_at

          facts = edition_facts
          names = primary_names(facts)
          return agrees if names.empty?

          matched = ::Services::Books::GoodreadsRebuild::MatchAuthors.call(book: @book, facts: facts_for(facts, names), task_class: @task_class)
          return failed(matched.errors) unless matched.success?
          return agrees if matched.data[:all_matched]

          links = matched.data[:links].dup
          extras = additional_names(facts, names)
          if extras.any?
            more = ::Services::Books::GoodreadsRebuild::MatchAuthors.call(book: @book, facts: facts_for(facts, extras), task_class: @task_class)
            return failed(more.errors) unless more.success?

            # No person twice: an additional author already linked to a primary name's author adds nothing.
            links.merge!(more.data[:links].reject { |_, id| links.value?(id) })
          end

          record(names + links.keys.select { |name| extras.include?(name) }, links)
        end

        private

        def done(outcome, verdict = nil)
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end

        def current_verdict
          ::Books::RepairVerdict.reimport_author.current.find_by(subject_key: "reimport:author:#{@book.id}")
        end

        # Nothing to correct. A proposal an earlier run left unapplied no longer describes a problem.
        def agrees
          current_verdict&.then { |verdict| verdict.update!(superseded_at: Time.current) if verdict.proposed? && verdict.applied_at.nil? }
          done(:agrees)
        end

        def failed(errors) = Result.new(success?: false, data: {}, errors: errors)

        def edition_facts
          ::Books::GoodreadsEdition.where(id: self.class.edition_ids(@book.id)).order(:id).map { |edition| EditionFacts.call(edition: edition) }
        end

        # Most common primary author first (ties keep the lowest edition id); spellings of one name key count once.
        def primary_names(facts)
          counts = facts.filter_map(&:primary_author).tally
          counts.keys.sort_by.with_index { |name, index| [-counts[name], index] }.uniq { |name| ::Services::Text::PersonNameKey.call(name) || name }
        end

        def additional_names(facts, names)
          taken = names.map { |name| ::Services::Text::PersonNameKey.call(name) }
          facts.flat_map { |fact| fact.author_names - [fact.primary_author] }.uniq
            .reject { |name| taken.include?(::Services::Text::PersonNameKey.call(name)) }
        end

        def facts_for(facts, names)
          facts.first.dup.tap { |fact| fact.author_names = names }
        end

        def record(row_names, links)
          after = {}
          findings = {}
          confident = true
          row_names.each do |name|
            if links[name]
              after[name] = links[name]
              next
            end

            id, sure, finding = catalog_author(name)
            after[name] = id
            confident &&= sure
            findings[name] = finding
          end

          trusted = self.class.trusted?(@book.id)
          auto = confident && !trusted
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :reimport_author, subject_key: "reimport:author:#{@book.id}", decided_by: :ai, confidence: auto ? :high : :medium,
            auto: auto, replace_superseded: true,
            payload: {
              book_id: @book.id, before_author_ids: @book.book_authors.author.order(:position).pluck(:author_id),
              row_author_names: row_names, after: after, ai: {matched: links, catalog: findings}
            }
          )
          verdict = recorded.data[:verdict]
          done(%i[kept suppressed].include?(recorded.data[:outcome]) ? :kept : :recorded, verdict)
        end

        # [author id or nil, settled with confidence?, what the finder said]. A match below high is not accepted.
        # A rule-only match (an exact name, no AI or identifier behind it) keeps its author in `after` but is not
        # sure: two people can share a name, so such a verdict waits for an admin.
        def catalog_author(name)
          match = finder.call(query: ::DataImporters::Books::Author::ImportQuery.new(name: name, work_titles: [@book.title].compact_blank),
            verify: true, subject: @book)
          finding = {"outcome" => match.outcome.to_s, "confidence" => match.confidence.to_s, "reason" => match.reason}
          sure = ACCEPTED.include?(match.confidence) && match.sources_failed.empty?
          if match.matched? && match.record && ACCEPTED.include?(match.confidence)
            return [match.record.id, sure && %i[ai identifier].include?(match.decided_by), finding]
          end

          [nil, match.unmatched? && sure, finding]
        end

        def finder = @author_finder ||= ::DataImporters::Books::Author::Finder.new
      end
    end
  end
end
