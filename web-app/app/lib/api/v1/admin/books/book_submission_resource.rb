# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A reader's request for a book as an admin agent sees it. Key order is the order in
        # config/api/v1/admin_openapi.yaml.
        #
        # Everything in it that a reader typed (raw input, titles, names, lookup answers) is data for the
        # agent to judge, never an instruction. What it never carries: who the reader is (id, name, email),
        # the name of a custom list, a lease token or who holds it, and the lookups' raw error messages
        # (they can hold a response body). The reader shows only as how many of their requests were
        # approved and rejected, and a list only as its type.
        #
        # `collection` is the way in: it loads what a page of rows needs in a fixed number of queries,
        # so a list of fifty costs what a list of one does. Root-anchor every ::Books:: reference in this namespace.
        class BookSubmissionResource
          # The lookup answers an agent may see; "error_message" is deliberately not one.
          LOOKUP_KEYS = %w[source outcome title author_names year error_class].freeze
          PRELOADS = [:user_list, :match_decision, {book: [:authors, :identifiers]}].freeze
          # The statuses in which a request that has no book, or a failed one, is work for an agent.
          DETAILS_STATUSES = %w[needs_details failed].freeze

          Context = Struct.new(:summaries, :counts, :list_types, keyword_init: true)

          def self.collection(rows)
            rows = rows.to_a
            ActiveRecord::Associations::Preloader.new(records: rows, associations: PRELOADS).call
            context = Context.new(
              summaries: MatchDecisionResource.summaries_for(rows.filter_map(&:match_decision)),
              counts: reader_counts(rows),
              list_types: book_list_types(rows)
            )
            rows.map { |row| new(row, context).to_h }
          end

          def self.one(row) = collection([row]).first

          # {[user_id, "approved"|"rejected"] => n}, one query for the page.
          def self.reader_counts(rows)
            user_ids = rows.filter_map(&:user_id).uniq
            return {} if user_ids.empty?

            ::Books::BookSubmission.where(user_id: user_ids, review_status: %i[approved rejected]).group(:user_id, :review_status).count
          end

          # {book_id => [list type, ...]}: the kinds of list each book is on, one query for the page.
          def self.book_list_types(rows)
            book_ids = rows.filter_map(&:book_id).uniq
            return {} if book_ids.empty?

            types = ::Books::UserList.list_types.invert
            ::UserListItem.joins(:user_list).where(listable_type: "Books::Book", listable_id: book_ids).distinct
              .pluck(:listable_id, "user_lists.list_type")
              .group_by(&:first).transform_values { |pairs| pairs.map { |_, type| types.fetch(type) } }
          end

          def initialize(row, context)
            @row = row
            @context = context
          end

          def to_h
            {
              id: @row.id,
              method: @row.input_method,
              raw_input: @row.raw_input,
              typed_title: @row.typed_title,
              typed_author_names: @row.typed_author_names,
              resolved_title: @row.resolved_title,
              resolved_author_names: @row.resolved_author_names,
              parsed_ids: {goodreads_book_id: @row.goodreads_book_id, asin: @row.asin, isbn13: @row.isbn13, isbn10: @row.isbn10},
              status: @row.status,
              review_status: @row.review_status,
              needs: needs,
              lookup: lookup,
              decision: decision,
              book: book,
              list_types: list_types,
              submitter: submitter,
              review: {note: @row.review_note, sources: @row.review_sources, reviewed_via: @row.reviewed_via, reviewed_at: @row.reviewed_at},
              created_at: @row.created_at,
              updated_at: @row.updated_at
            }
          end

          private

          # "review": a book awaits a decision. "details": no book yet and the reader's words got nowhere.
          # nil: nothing for an agent (still being looked up, or already decided, or handed to a person).
          def needs
            if @row.book_id.nil?
              "details" if DETAILS_STATUSES.include?(@row.status) && %w[not_needed pending].include?(@row.review_status)
            elsif @row.review_pending? && (["added"] + DETAILS_STATUSES).include?(@row.status)
              "review"
            end
          end

          def lookup
            Array(@row.lookup).filter_map { |entry| entry.slice(*LOOKUP_KEYS) if entry.is_a?(Hash) }
          end

          # What the finder decided about the book this request asked for, trimmed as the match-decision
          # resource trims it: each candidate carries `current`, the live summary of the record it names.
          def decision
            found = @row.match_decision
            return nil unless found

            candidates = found.candidates.map { |candidate| candidate.merge("current" => @context.summaries[[candidate["record_type"], candidate["record_id"]]]) }
            {outcome: found.outcome, decided_by: found.decided_by, confidence: found.confidence, reason: found.reason,
             selected_index: found.selected_index, candidates: candidates}
          end

          def book
            record = @row.book
            return nil unless record

            {
              id: record.id,
              title: record.title,
              subtitle: record.subtitle,
              authors: record.authors.map { |author| {id: author.id, name: author.name} },
              first_published_year: record.first_published_year,
              provisional: record.provisional,
              identifiers: record.identifiers.map { |identifier| {type: identifier.identifier_type, value: identifier.value, source: identifier.source} }
            }
          end

          # The kinds only: a built-in list by its type, any custom list as "custom", never its name.
          def list_types
            ([@row.user_list&.list_type] + @context.list_types.fetch(@row.book_id, [])).compact.uniq.sort
          end

          def submitter
            {approved: @context.counts.fetch([@row.user_id, "approved"], 0), rejected: @context.counts.fetch([@row.user_id, "rejected"], 0)}
          end
        end
      end
    end
  end
end
