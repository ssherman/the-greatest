# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # Writes an import's rows to the member's library in one pass (Goodreads
      # import spec §7). Not Services::UserLists::AddItem per row: that dates
      # a read item today and fires per-item side effects. The list rules are
      # the same.
      #
      # - read, to-read, currently-reading go to the read, want to read and
      #   reading lists. A read book leaves the reading list, and is never put
      #   on it by the same import. Read is dated from Date Read, never today.
      # - Every other shelf, exclusive or not, is a custom list named after the
      #   shelf with hyphens as spaces, matched case-insensitively. A
      #   "favorites" shelf is a custom list too, never the favorites list,
      #   which feeds the generated users' favorites list.
      # - New items follow Bookshelves with positions and go after the items
      #   already there; created_at is Date Added, else the import time.
      # - Additive: an existing item is never moved, only a blank completed_on
      #   filled, and nothing is deleted except the reading item a read book
      #   replaces. The same file twice changes nothing.
      #
      # Each row's `applied` records the ids it wrote, for Revert. A row whose
      # book this import wrote nothing for is skipped.
      #
      # Runs under the user's row lock, the lock the list-item controller takes,
      # so a member editing lists meanwhile waits rather than interleaves.
      class WriteLibrary
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        DEFAULT_SHELVES = {"read" => :read, "to-read" => :want_to_read, "currently-reading" => :reading}.freeze
        SKIPPED_DETAIL = "already on your lists"
        UNMATCHED_ERROR = "could not be matched to a book"
        REVIEW_BREAK = %r{<br\s*/?>}i

        # One list item this import wants: the list, the book, the rows behind
        # it (the lowest-numbered one records it), and the shelf it came from.
        Want = Struct.new(:list, :book_id, :rows, :shelf, keyword_init: true)

        def self.call(import:)
          new(import: import).call
        end

        def initialize(import:)
          @import = import
          @user = import.user
          @written = Hash.new { |hash, row_id| hash[row_id] = {"list_item_ids" => []} }
          @completion_changed = false
          @touched_list_ids = Set.new
          @touched_book_ids = Set.new
        end

        def call
          purge_urls = []
          @user.with_lock do
            # Revert takes this same user lock: an import it rejected (or an
            # admin reran) while this waited is not this run's to write.
            @import.reload
            next unless @import.writing? && !@import.review_rejected?

            settle_unwritable_rows
            rows = writable_rows
            by_book = rows.group_by { |row| row.goodreads_edition.book_id }
            write_items(by_book) if by_book.any?
            write_reviews(by_book)
            finish(rows, by_book)
            ::UserList.where(id: @touched_list_ids.to_a).touch_all if @touched_list_ids.any?
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_user(user: @user) if @completion_changed
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          @touched_book_ids.each { |book_id| ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book_id) }
          @import.update!(skipped_count: @import.rows.skipped.count)
          Result.new(success?: true, data: @import.rows.group(:outcome).count.symbolize_keys.merge(purge_urls: purge_urls), errors: [])
        end

        private

        # Pending rows that cannot be written: a parked edition's rows are
        # parked, and an edition the resolver never settled fails its rows
        # with the resolver's error. An edition still waiting on Goodreads is
        # left alone: the import is not finished with it.
        def settle_unwritable_rows
          @import.rows.pending.where.not(goodreads_edition_id: nil).includes(:goodreads_edition).find_each do |row|
            edition = row.goodreads_edition
            next if edition.book_id.present? || edition.verification_pending?

            if edition.parked?
              row.update!(outcome: :parked, outcome_detail: SettleEdition::PARKED_DETAIL.fetch(edition.verification.to_sym, "not found on Goodreads"))
            else
              row.update!(outcome: :failed, error: row.error.presence || UNMATCHED_ERROR)
            end
          end
        end

        def writable_rows
          @import.rows.pending.joins(:goodreads_edition).where.not(books_goodreads_editions: {book_id: nil})
            .includes(:goodreads_edition).order(:row_number).to_a
        end

        def write_items(by_book)
          lists = default_lists
          wants = by_book.flat_map { |book_id, rows| wants_for(book_id, rows, lists) }
          existing = existing_items(wants)
          inserts = Hash.new { |hash, list| hash[list] = [] }

          wants.each do |want|
            item = existing[[want.list.id, want.book_id]]
            if item
              fill_completion(item, want)
            else
              inserts[want.list] << want
            end
          end
          remove_from_reading(by_book.keys.select { |book_id| reading_replaced?(by_book[book_id]) }, lists)
          inserts.each { |user_list, list_wants| insert(user_list, list_wants) }
        end

        def default_lists
          existing = ::Books::UserList.where(user: @user).to_a
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: existing)
            .select { |list| list.is_a?(::Books::UserList) && list.default? }.index_by { |list| list.list_type.to_sym }
        end

        def wants_for(book_id, rows, lists)
          shelves = Hash.new { |hash, shelf| hash[shelf] = [] }
          rows.each do |row|
            shelves[row.exclusive_shelf] << row if row.exclusive_shelf.present?
            row.shelves.each { |shelf| shelves[shelf] << row unless DEFAULT_SHELVES.key?(shelf) }
          end
          shelves.delete("currently-reading") if shelves.key?("read")

          shelves.map do |shelf, shelf_rows|
            list = DEFAULT_SHELVES.key?(shelf) ? lists.fetch(DEFAULT_SHELVES[shelf]) : custom_list(shelf)
            Want.new(list: list, book_id: book_id, rows: shelf_rows.uniq.sort_by(&:row_number), shelf: shelf)
          end
        end

        def reading_replaced?(rows)
          rows.any? { |row| row.exclusive_shelf == "read" }
        end

        def custom_list(shelf)
          name = shelf.tr("-", " ").squish
          @custom_lists ||= ::Books::UserList.custom.where(user: @user).to_a.index_by { |list| list.name.downcase.squish }
          @custom_lists[name.downcase] ||= ::Books::UserList.create!(user: @user, list_type: :custom, name: name)
        end

        def existing_items(wants)
          return {} if wants.empty?

          ::UserListItem.where(user_list_id: wants.map { |want| want.list.id }.uniq, listable_type: "Books::Book",
            listable_id: wants.map(&:book_id).uniq).index_by { |item| [item.user_list_id, item.listable_id] }
        end

        def completed_on(want)
          return nil unless want.list.completed_on_enabled?

          want.rows.filter_map(&:date_read).max
        end

        def fill_completion(item, want)
          date = completed_on(want)
          return if date.nil? || item.completed_on.present?

          item.update!(completed_on: date)
          @completion_changed = true
          @touched_list_ids << item.user_list_id
        end

        def remove_from_reading(book_ids, lists)
          reading = lists[:reading]
          return if reading.nil? || book_ids.empty?

          reading.user_list_items.where(listable_type: "Books::Book", listable_id: book_ids).find_each(&:destroy!)
        end

        def insert(user_list, list_wants)
          start = ::UserListItem.where(user_list_id: user_list.id).maximum(:position).to_i
          ordered = list_wants.sort_by do |want|
            positions = want.rows.filter_map { |row| row.shelf_positions[want.shelf] }
            [positions.min || Float::INFINITY, want.rows.first.row_number]
          end
          now = Time.current
          records = ordered.each_with_index.map do |want, index|
            date_added = want.rows.filter_map(&:date_added).min
            {user_list_id: user_list.id, listable_type: "Books::Book", listable_id: want.book_id,
             position: start + index + 1, completed_on: completed_on(want),
             created_at: date_added&.in_time_zone || @import.created_at, updated_at: now}
          end
          inserted = ::UserListItem.insert_all(records, unique_by: :index_user_list_items_on_list_and_listable_unique,
            returning: %w[id listable_id])
          by_book = ordered.index_by(&:book_id)
          inserted.rows.each do |id, listable_id|
            want = by_book.fetch(listable_id)
            @written[want.rows.first.id]["list_item_ids"] << id
            @completion_changed ||= completed_on(want).present?
          end
          @touched_list_ids << user_list.id if inserted.rows.any?
        end

        # One deterministic review per book (spec §7): the row with a rating,
        # then the latest Date Read, then the lowest row number. Rating 0 with
        # text is an unrated review; rating 0 and no text is nothing. An
        # existing review by the user is left as it is. Validated as a model
        # (the sanitizer and the length rule run) and inserted in bulk, so the
        # per-review summary callback does not fire; `call` recalculates once
        # per book instead.
        def write_reviews(by_book)
          reviewed = ::Review.where(user: @user, reviewable_type: "Books::Book", reviewable_id: by_book.keys).pluck(:reviewable_id).to_set
          by_book.each do |book_id, rows|
            next if reviewed.include?(book_id)

            winner = rows.select { |row| row.rating.to_i.positive? || row.review_body.present? }
              .min_by { |row| [row.rating.to_i.positive? ? 0 : 1, -(row.date_read&.jd || 0), row.row_number] }
            write_review(book_id, winner) if winner
          end
        end

        def write_review(book_id, row)
          review = ::Review.new(user: @user, reviewable_type: "Books::Book", reviewable_id: book_id,
            rating: (row.rating if row.rating.to_i.positive?), body: row.review_body&.gsub(REVIEW_BREAK, "\n"))
          unless review.valid?
            row.update!(error: "review not imported: #{review.errors.full_messages.to_sentence}")
            return
          end

          now = Time.current
          attributes = review.attributes.slice("user_id", "reviewable_type", "reviewable_id", "rating", "body", "title")
            .merge("created_at" => (row.date_read || row.date_added)&.in_time_zone || @import.created_at, "updated_at" => now)
          inserted = ::Review.insert_all([attributes], unique_by: :index_reviews_on_user_and_reviewable, returning: %w[id])
          return if inserted.rows.empty?

          @written[row.id]["review_id"] = inserted.rows.first.first
          @touched_book_ids << book_id
        end

        def finish(rows, by_book)
          wrote = by_book.select { |_book_id, book_rows| book_rows.any? { |row| written?(row) } }.keys.to_set
          rows.each do |row|
            applied = @written.key?(row.id) ? @written[row.id].reject { |_key, value| value.blank? } : {}
            if wrote.include?(row.goodreads_edition.book_id)
              row.update!(outcome: :applied, outcome_detail: nil, applied: applied)
            else
              row.update!(outcome: :skipped, outcome_detail: SKIPPED_DETAIL, applied: applied)
            end
          end
        end

        def written?(row)
          @written.key?(row.id) && @written[row.id].values.any?(&:present?)
        end
      end
    end
  end
end
