# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Compares the resolver's answer for an edition with the book legacy chose
      # for each replay user who has it (Goodreads import spec §12.4), and
      # writes each replay row's finding.
      #
      # Findings:
      # - agrees: same book;
      # - duplicate: legacy's book and the resolver's are already a suspected
      #   pair, which the merge will settle;
      # - disagrees: another book;
      # - unmatched: no book;
      # - no_legacy_choice: legacy has nothing for this user.
      #
      # Verdicts come only from the final pass for the edition. On pass one, a
      # disagreement or an unmatched edition waits for the full pass
      # (awaiting_full_pass). On the final pass:
      # - a disagreement is a relink for that user. It is approved on its own
      #   only when a rule decided it at certain or high confidence;
      #   otherwise it is proposed. When legacy's book contradicts the row on
      #   both title and author, legacy's identifier was the mistake, so the
      #   relink also moves the row's identifiers.
      # - an unmatched edition whose legacy book contradicts the row on both
      #   counts proposes stripping those identifiers, with any cached Goodreads
      #   page attached. Any other unmatched edition is only counted.
      #
      # Writes findings and verdicts only, never catalog data.
      class CompareEdition
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WAITS_FOR_FULL_PASS = %i[disagrees unmatched].freeze

        def self.call(edition:, match:, finder:, query:, final:)
          new(edition: edition, match: match, finder: finder, query: query, final: final).call
        end

        def initialize(edition:, match:, finder:, query:, final:)
          @edition = edition
          @match = match
          @finder = finder
          @query = query
          @final = final
          @resolved = match.matched? ? match.record : nil
        end

        def call
          tally = Hash.new(0)
          replay_rows.group_by { |row| row.import.user_id }.each do |user_id, rows|
            legacy = LegacyChoice.call(goodreads_book_id: @edition.goodreads_book_id, user_id: user_id)
            finding = finding_for(legacy)
            finding = :awaiting_full_pass if !@final && WAITS_FOR_FULL_PASS.include?(finding)
            record(finding, user_id, rows, legacy) if @final
            ::Books::GoodreadsImportRow.where(id: rows.map(&:id))
              .update_all(replay_finding: ::Books::GoodreadsImportRow.replay_findings.fetch(finding.to_s),
                legacy_book_id: legacy&.id, updated_at: Time.current)
            tally[finding] += rows.size
          end
          Result.new(success?: true, data: {needs_full_pass: tally.key?(:awaiting_full_pass), tally: tally.to_h}, errors: [])
        end

        private

        def replay_rows
          ::Books::GoodreadsImportRow.joins(:import).merge(::Books::GoodreadsImport.legacy_replay)
            .where(goodreads_edition_id: @edition.id).includes(:import).order(:id).to_a
        end

        def finding_for(legacy)
          return :no_legacy_choice if legacy.nil?
          return :unmatched if @resolved.nil?
          return :agrees if @resolved.id == legacy.id
          return :duplicate if suspected_pair?(legacy, @resolved)

          :disagrees
        end

        def suspected_pair?(book_a, book_b)
          a, b = [book_a.id, book_b.id].minmax
          ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: a, item_b_id: b).where.not(status: :not_duplicate).exists?
        end

        def record(finding, user_id, rows, legacy)
          case finding
          when :disagrees then record_relink(user_id, rows, legacy)
          when :unmatched then record_strip(user_id, rows, legacy) if contradicts?(legacy)
          end
        end

        def record_relink(user_id, rows, legacy)
          RecordVerdict.call(
            kind: :relink, subject_key: "user:#{user_id}:book:#{legacy.id}:goodreads:#{@edition.goodreads_book_id}",
            payload: base_payload(user_id, rows).merge(
              from_book_id: legacy.id, to_book_id: @resolved.id,
              strip_identifiers: contradicts?(legacy) ? held_identifiers(legacy) : []
            ),
            decided_by: decider, confidence: @match.confidence, reason: @match.reason,
            ai_chat_id: @match.decision&.ai_chat_id, auto: decider == :rule && %i[certain high].include?(@match.confidence)
          )
        end

        def record_strip(user_id, rows, legacy)
          RecordVerdict.call(
            kind: :strip_identifier, subject_key: "book:#{legacy.id}:books_work_goodreads_id:#{@edition.goodreads_book_id}",
            payload: base_payload(user_id, rows).merge(book_id: legacy.id, remove: held_identifiers(legacy), add: [],
              goodreads_page: page_facts),
            decided_by: decider, confidence: @match.confidence, ai_chat_id: @match.decision&.ai_chat_id,
            reason: "#{@match.reason}; legacy's book matches neither the row's title nor its author", auto: false
          )
        end

        def base_payload(user_id, rows)
          {user_id: user_id, goodreads_book_id: @edition.goodreads_book_id,
           rows: rows.map { |row| [row.import.legacy_import_id, row.row_number] },
           match_decision_id: @match.decision&.id, row: {title: @edition.title, author: @edition.primary_author}}
        end

        def contradicts?(book)
          !@finder.titles_agree?(@query, book) && !@finder.creators_agree?(@query, book)
        end

        # The row's own identifiers that the book holds: its Goodreads id (bare or
        # slug form) and its ISBNs.
        def held_identifiers(book)
          id = @edition.goodreads_book_id.to_s
          goodreads = book.identifiers.where(identifier_type: :books_work_goodreads_id).pluck(:value)
            .select { |value| value[/\A\d+/] == id }.sort.map { |value| ["books_work_goodreads_id", value] }
          isbns = [["books_work_isbn13", @edition.isbn13], ["books_work_isbn10", @edition.isbn10]].select do |type, value|
            value.present? && book.identifiers.exists?(identifier_type: type, value: value)
          end
          goodreads + isbns
        end

        def page_facts
          page = ::Books::GoodreadsPage.conclusive.find_by(goodreads_book_id: @edition.goodreads_book_id)
          page && {outcome: page.outcome, title: page.title, authors: page.contributors.map(&:name)}
        end

        def decider
          %i[identifier rule].include?(@match.decided_by) ? :rule : :ai
        end
      end
    end
  end
end
