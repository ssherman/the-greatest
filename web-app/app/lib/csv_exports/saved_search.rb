# frozen_string_literal: true

# Exports a saved search by paging its query (spec §9): OpenSearch picks the
# ids, SavedSearchQuery hydrates a page, and the books row class writes it.
# Stops at the limit, at a short page, or at the last page inside OpenSearch's
# 10,000-result window, whichever comes first. hide_read stays about the
# search's owner, exactly as on the page.
#
# Books-only in effect: saved searches exist on no other domain, and the
# controller 404s a host without them before this is reached.
module CsvExports
  class SavedSearch
    PER_PAGE = 1000

    def self.max_page(per_page:)
      ::Books::SavedSearchQuery.max_page(per_page: per_page)
    end

    def self.call(search:, limit:, io:)
      row_class = Books::RankedBookRow
      writer = Writer.new(io, headers: row_class::HEADERS)
      per_page = limit ? [limit, PER_PAGE].min : PER_PAGE
      last_page = max_page(per_page: per_page)
      query_class = search.class.query_class

      page = 1
      loop do
        books = query_class.call(criteria: search.criteria_object, owner: search.user, page: page, per_page: per_page).books
        break if books.empty?

        ActiveRecord::Associations::Preloader.new(records: books, associations: row_class.preloads).call
        ctx = row_class.context(books.map(&:id))
        books.each do |book|
          break if limit && writer.rows >= limit

          writer.row(row_class.row_for_book(book, rank: book.ranked_position, score: book.ranked_score, ctx: ctx))
        end

        break if (limit && writer.rows >= limit) || books.size < per_page || page >= last_page

        page += 1
      end

      writer.rows
    end
  end
end
