# frozen_string_literal: true

module Services
  module Books
    module Evidence
      # Finds the Wikidata item for a book's written work, by id and never by
      # text search (spec 4.3). In order: the stored QID, statements on the
      # book's Goodreads / Open Library / OCLC ids, then the works of the
      # book's authors that share its title. A candidate is accepted only when
      # it is a written work (an edition is followed once to its work) and
      # does not name authors that are not ours. More than one distinct
      # accepted QID within a strategy means none, and the next strategy runs.
      #
      # A candidate that fails the check is recorded in data[:rejected] with a
      # reason: not_written_work, author_mismatch, ambiguous_edition (an edition
      # of several works, or of another edition), edition_without_work,
      # unparseable, not_kept (a stored QID outside the service's copy, which also ends resolution),
      # title_mismatch (a stored or statement hit whose label is not
      # the book's title or an alternate title), ambiguous_statements, ambiguous_title.
      #
      # A stored QID that fails acceptance, or whose entity is gone, is removed when
      # it was written by this resolver (source wikidata). A QID already held by
      # another book is stored on neither, and an unmerged duplicate
      # candidate naming it keeps both books from taking it again.
      #
      # The book's verified ISBN-13s go out as P212 statements too. Wikidata holds
      # P212 hyphenated and the local Wikidata service stores ISBN-13 and ISBN-10 in
      # one normalised form, so the bare digits match; an edition found this way is
      # followed to its work by its P629. Unverified ISBNs are never used.
      #
      # A stored QID the service does not hold is removed only when Wikidata itself
      # does not have it. One reported by the client's not_kept exists but lies outside
      # the service's copy (it is not a book, author or work-like item), so the stored
      # row is left alone and resolution stops there: no other strategy runs, the result
      # has no QID, and the rejection is recorded as not_kept.
      class ResolveWikidataWork
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        WorkLike = ::Services::Books::Verification::WorldCatCheck::WorkLike
        Check = ::Services::Books::Verification::Check
        STATEMENT_IDS = {
          "P2969" => "books_work_goodreads_id",
          "P648" => "books_work_openlibrary_id",
          "P243" => "books_work_oclc_id"
        }.freeze
        MAX_STATEMENT_PAIRS = 50
        ANONYMOUS_QID = "Q4233718"
        MAX_ISBN_PAIRS = 10
        NOT_KEPT = :not_kept

        def self.call(book:, client: ::Wikidata::Client.new)
          new(book: book, client: client).call
        end

        def initialize(book:, client:)
          @book = book
          @client = client
          @rejected = []
          @author_qids = nil
        end

        def call
          qid, work, via = resolve
          return finish(nil, nil, nil) if qid.nil?

          commit(qid, work, via)
        end

        private

        def resolve
          stored = from_stored
          return [nil, nil, nil] if stored == NOT_KEPT

          stored || from_statements || from_author_works || [nil, nil, nil]
        end

        def from_stored
          stored = own_rows.first&.value
          return if stored.blank?

          entity = @client.entities([stored])[stored]
          work = entity && accept(entity, check_title: true)
          return [work.id, work, "stored"] if work
          if entity.nil?
            # Neither answer proves the QID is wrong. not_kept: Wikidata has it but we do not
            # distil it. missing: absent from a weekly snapshot, whose redirect dump can be weeks
            # older than the JSON dump, and a QID stored since may be newer than the dump. A miss
            # is weaker than a live 404, so the stored row stays and resolution ends here.
            reason = @client.not_kept.include?(stored) ? "not_kept" : "missing"
            @rejected << {"id" => stored, "reason" => reason}
            return NOT_KEPT
          end

          own_rows.first.destroy! if own_rows.first&.source_wikidata?
          nil
        end

        # Every id the book holds, Goodreads first. The search is asked for as many
        # hits as there are pairs; an answer that long may have been cut off, and a
        # second, conflicting work could sit in the missing part, so it is ambiguous.
        def from_statements
          pairs = STATEMENT_IDS.flat_map do |property, type|
            own_identifiers.where(identifier_type: type).order(:id).pluck(:value).compact_blank.map { |value| [property, value] }
          end
          isbns = own_identifiers.verified.where(identifier_type: :books_work_isbn13).order(:id).pluck(:value).compact_blank
            .first(MAX_ISBN_PAIRS).map { |value| ["P212", value] }
          pairs = pairs.first(MAX_STATEMENT_PAIRS - isbns.size) + isbns
          return if pairs.empty?

          ids = @client.by_statements(pairs, limit: MAX_STATEMENT_PAIRS)
          if ids.size >= MAX_STATEMENT_PAIRS
            @rejected << {"id" => nil, "reason" => "ambiguous_statements"}
            return
          end

          unique_work(ids, "ambiguous_statements", "statements")
        end

        def from_author_works
          qids = author_qids
          return if qids.empty?

          candidates = @client.work_items(qids).values.flatten.select do |item|
            Check.titles_agree?(@book, WorkLike.new(title: item["label"], subtitle: nil, author_names: [], author_keys: []))
          end
          unique_work(candidates.map { |item| item["id"] }, "ambiguous_title", "author_works")
        end

        def unique_work(ids, ambiguity, via)
          check_title = via != "author_works"
          ids = ids.uniq
          return if ids.empty?

          entities = @client.entities(ids)
          works = ids.filter_map { |id| entities[id] && accept(entities[id], check_title: check_title) }.uniq(&:id)
          return [works.first.id, works.first, via] if works.size == 1

          works.each { |work| @rejected << {"id" => work.id, "reason" => ambiguity} }
          nil
        end

        # The distilled Work when the entity passes the check, else nil with the reason recorded.
        def accept(entity, check_title: false)
          work = distill(entity)
          return reject(entity.is_a?(Hash) ? entity["id"] : nil, "unparseable") if work.nil?

          if work.edition?
            targets = work.edition_of
            return reject(work.id, "edition_without_work") if targets.empty?
            return reject(work.id, "ambiguous_edition") unless targets.size == 1

            target = @client.entities(targets)[targets.first]
            return reject(targets.first, "not_written_work") if target.nil?

            work = distill(target)
            return reject(targets.first, "unparseable") if work.nil?
            return reject(work.id, "ambiguous_edition") if work.edition?
          end
          return reject(work.id, "not_written_work") unless work.written_work?
          return reject(work.id, "author_mismatch") unless authors_ok?(work)
          return reject(work.id, "title_mismatch") if check_title && !title_ok?(work)

          work
        end

        def distill(entity)
          ::Wikidata::Work.from_payload(::Wikidata::WorkDistiller.call(entity))
        rescue ::Wikimedia::Exceptions::ParseError
          nil
        end

        def reject(id, reason)
          @rejected << {"id" => id, "reason" => reason}
          nil
        end

        def title_ok?(work)
          Check.titles_agree?(@book, WorkLike.new(title: work.label, subtitle: nil, author_names: [], author_keys: []))
        end

        def authors_ok?(work)
          return work.authors.all? { |qid| qid == ANONYMOUS_QID } if only_placeholder_or_place_authors?
          return true if work.authors.empty?
          return false if @book.authors.empty?
          return true if work.authors.intersect?(author_qids)

          # An author we hold a QID for is identified by it: a different P50 QID is a
          # different person, however alike the names. Names only stand in for the
          # authors that have no QID.
          unkeyed = unkeyed_authors
          return false if unkeyed.empty?

          names = @client.labels(work.authors).values
          Check.authors_agree?(UnkeyedAuthors.new(authors: unkeyed), WorkLike.new(title: nil, subtitle: nil, author_names: names, author_keys: []))
        end

        UnkeyedAuthors = Data.define(:authors)

        # Books by "Unknown" or a place ("China") have no person for Wikidata to name,
        # so the work may carry no author or Wikidata's "anonymous"; any other author
        # is someone else's work.
        def only_placeholder_or_place_authors?
          authors = @book.authors.to_a
          authors.any? && authors.all? { |author| ::Services::Books::Authors::AuthorKind.kind(author) != :person }
        end

        def unkeyed_authors
          keyed = ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: @book.authors.map(&:id),
            identifier_type: :books_author_wikidata_qid).pluck(:identifiable_id)
          @book.authors.reject { |author| keyed.include?(author.id) }
        end

        def author_qids
          @author_qids ||= ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: @book.authors.map(&:id),
            identifier_type: :books_author_wikidata_qid).pluck(:value).uniq
        end

        def own_identifiers = ::Identifier.where(identifiable_type: "Books::Book", identifiable_id: @book.id)

        def own_rows = own_identifiers.where(identifier_type: :books_work_wikidata_qid).order(:id)

        def holder_of(qid)
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: :books_work_wikidata_qid, value: qid)
            .where.not(identifiable_id: @book.id).order(:id).first
        end

        # Holder check, block check and store happen under one per-QID advisory lock,
        # so two books resolving the same QID at once cannot both store it.
        def commit(qid, work, via)
          conflict_id = nil
          ::Identifier.transaction do
            connection = ::Identifier.connection
            connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(qid)}))")
            holder = holder_of(qid)
            if holder
              record_collision(qid, via, holder)
              conflict_id = holder.identifiable_id
            elsif (blocker = blocking_candidate(qid))
              drop_own_row(qid)
              conflict_id = [blocker.item_a_id, blocker.item_b_id].find { |id| id != @book.id }
            else
              store(qid)
            end
          end
          return finish(nil, nil, nil, conflict_book_id: conflict_id) if conflict_id

          finish(qid, work, via)
        end

        # Flag keeps its own savepoint around each attempt, so its retry after a lost
        # insert race works inside the lock's transaction.
        def record_collision(qid, via, holder)
          result = ::Services::DuplicateCandidates::Flag.call(
            item_type: "Books::Book", ids: [@book.id, holder.identifiable_id], source: :identifier_collision,
            evidence: {"wikidata_qid" => qid, "via" => via}
          )
          note_qid(result.data, qid)
          holder.destroy! if holder.source_wikidata?
          drop_own_row(qid)
        end

        # Flag leaves a dismissed pair untouched and keeps a pending pair's first source
        # and evidence, so the QID is written onto whatever row the pair has. A pair can
        # collide on several QIDs over time, hence the list.
        def note_qid(candidate, qid)
          return if candidate.nil? || candidate.merged?

          qids = Array(candidate.evidence["wikidata_qids"])
          return if qids.include?(qid)

          candidate.update_columns(evidence: candidate.evidence.merge("wikidata_qids" => qids + [qid]))
        end

        def drop_own_row(qid)
          own_rows.where(value: qid, source: :wikidata).destroy_all
        end

        # A pair of any source that nobody has merged keeps the QID off both books, so a
        # dismissed pair still blocks: the QID was wrong for at least one of them. Older
        # rows carry it as wikidata_qid, later ones in the wikidata_qids list.
        def blocking_candidate(qid)
          ::DuplicateCandidate.where(item_type: "Books::Book", status: [:pending, :not_duplicate])
            .where("evidence->>'wikidata_qid' = :qid OR jsonb_exists(evidence->'wikidata_qids', :qid)", qid: qid)
            .order(:id).first
        end

        def store(qid)
          rows = own_rows.to_a
          return if rows.size == 1 && rows.first.value == qid

          rows.each(&:destroy!)
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_wikidata_qid, value: qid, source: :wikidata)
        end

        def finish(qid, work, via, conflict_book_id: nil)
          Result.new(success?: true, errors: [],
            data: {qid: qid, via: via, work: work, conflict_book_id: conflict_book_id, rejected: @rejected})
        end
      end
    end
  end
end
