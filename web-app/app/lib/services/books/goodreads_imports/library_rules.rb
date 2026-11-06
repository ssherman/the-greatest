# frozen_string_literal: true

module Services
  module Books
    module GoodreadsImports
      # The list and review rules of a Goodreads import (spec §7), shared by
      # WriteLibrary (a whole import, batch insert) and write_row (one row of a
      # finished import onto one book, for the legacy re-import). Both paths
      # take the shelf-to-list mapping, the completed_on rule and the review
      # choice and text from here, so they cannot drift apart.
      module LibraryRules
        DEFAULT_SHELVES = {"read" => :read, "to-read" => :want_to_read, "currently-reading" => :reading}.freeze
        REVIEW_BREAK = %r{<br\s*/?>}i

        module_function

        # The user's default books lists by type, created when missing.
        def default_lists(user)
          existing = ::Books::UserList.where(user: user).to_a
          ::Services::UserLists::EnsureDefaults.call(user: user, domain: :books, existing: existing)
            .select { |list| list.is_a?(::Books::UserList) && list.default? }.index_by { |list| list.list_type.to_sym }
        end

        # `cache` is the caller's to keep (a Hash), so a batch looks the user's
        # custom lists up once. Matched case-insensitively, created if missing.
        def custom_list(user, shelf, cache)
          name = shelf.tr("-", " ").squish
          cache[:loaded] ||= ::Books::UserList.custom.where(user: user).to_a.index_by { |list| list.name.downcase.squish }
          cache[:loaded][name.downcase] ||= ::Books::UserList.create!(user: user, list_type: :custom, name: name)
        end

        def list_for(user, shelf, lists, cache)
          DEFAULT_SHELVES.key?(shelf) ? lists.fetch(DEFAULT_SHELVES[shelf]) : custom_list(user, shelf, cache)
        end

        def completed_on(list, rows)
          return nil unless list.completed_on_enabled?

          rows.filter_map(&:date_read).max
        end

        # The row whose rating and text become the book's review: the row with
        # a rating, then the latest Date Read, then the lowest row number.
        # Rating 0 with text is an unrated review; rating 0 and no text is
        # nothing.
        def review_winner(rows)
          rows.select { |row| row.rating&.positive? || row.review_body.present? }
            .min_by { |row| [row.rating&.positive? ? 0 : 1, -(row.date_read&.jd || 0), row.row_number] }
        end

        def build_review(user, book_id, row)
          ::Review.new(user: user, reviewable_type: "Books::Book", reviewable_id: book_id,
            rating: (row.rating if row.rating&.positive?), body: row.review_body&.gsub(REVIEW_BREAK, "\n"))
        end

        # The insert_all attributes for a valid review. Inserted in bulk so the
        # per-review summary callback does not fire; the caller recalculates.
        def review_attributes(review, row, fallback_created_at)
          review.attributes.slice("user_id", "reviewable_type", "reviewable_id", "rating", "body", "title")
            .merge("created_at" => (row.date_read || row.date_added)&.in_time_zone || fallback_created_at, "updated_at" => Time.current)
        end

        # The shelves a single row puts the book on. A read book is never put
        # on the reading list.
        def shelves_of(row)
          shelves = []
          shelves << row.exclusive_shelf if row.exclusive_shelf.present?
          row.shelves.each { |shelf| shelves << shelf unless DEFAULT_SHELVES.key?(shelf) }
          shelves = shelves.uniq
          shelves.delete("currently-reading") if shelves.include?("read")
          shelves
        end

        # The lists the user already has that write_row would put this row's book on (same shelf-to-list mapping),
        # without creating any. Used to ask what a row says without writing it.
        def existing_lists_for(user, row)
          lists = ::Books::UserList.where(user: user).to_a
          shelves_of(row).filter_map do |shelf|
            if DEFAULT_SHELVES.key?(shelf)
              lists.find { |list| list.default? && list.list_type.to_sym == DEFAULT_SHELVES[shelf] }
            else
              name = shelf.tr("-", " ").squish.downcase
              lists.find { |list| list.custom? && list.name.downcase.squish == name }
            end
          end
        end

        # Writes one row for one user onto one book, whatever the import's
        # status. Additive and idempotent like WriteLibrary: an existing item
        # only gets a blank completed_on filled, a read book drops its reading
        # item, an existing review is left alone. review: false writes the list
        # items only (a copy whose review is moved, not rewritten from the CSV). Returns the ids of the list
        # items the row now has on the book, created or already there.
        def write_row(user:, row:, book:, fallback_created_at:, review: true)
          purge_urls = []
          result = nil
          user.with_lock do
            lists = default_lists(user)
            cache = {}
            completion_changed = false
            touched = Set.new
            item_ids = shelves_of(row).map do |shelf|
              list = list_for(user, shelf, lists, cache)
              item = ::UserListItem.find_by(user_list_id: list.id, listable_type: "Books::Book", listable_id: book.id)
              date = completed_on(list, [row])
              if item
                if date && item.completed_on.blank?
                  item.update!(completed_on: date)
                  completion_changed = true
                  touched << list.id
                end
                item.id
              else
                completion_changed ||= date.present?
                touched << list.id
                insert_item(list, book, row, date, fallback_created_at)
              end
            end
            if row.exclusive_shelf == "read" && lists[:reading]
              lists[:reading].user_list_items.where(listable_type: "Books::Book", listable_id: book.id).find_each(&:destroy!)
            end
            ::UserList.where(id: touched.to_a).touch_all if touched.any?
            result = {list_item_ids: item_ids, review_id: (write_review(user, book, row, fallback_created_at) if review)}
            purge_urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_user(user: user) if completion_changed
          end
          if purge_urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", purge_urls) }
          end
          ::Services::Reviews::SummaryRecalculator.recalculate("Books::Book", book.id) if result[:review_id]
          result
        end

        # Returns the new item's id.
        def insert_item(list, book, row, completed_on, fallback_created_at)
          position = ::UserListItem.where(user_list_id: list.id).maximum(:position).to_i + 1
          inserted = ::UserListItem.insert_all([{user_list_id: list.id, listable_type: "Books::Book", listable_id: book.id,
                                                 position: position, completed_on: completed_on,
                                                 created_at: row.date_added&.in_time_zone || fallback_created_at, updated_at: Time.current}],
            unique_by: :index_user_list_items_on_list_and_listable_unique, returning: %w[id])
          return inserted.rows.first.first if inserted.rows.any?

          ::UserListItem.find_by!(user_list_id: list.id, listable_type: "Books::Book", listable_id: book.id).id
        end

        def write_review(user, book, row, fallback_created_at)
          return nil if ::Review.exists?(user: user, reviewable_type: "Books::Book", reviewable_id: book.id)
          return nil unless review_winner([row])

          review = build_review(user, book.id, row)
          unless review.valid?
            row.update!(error: "review not imported: #{review.errors.full_messages.to_sentence}")
            return nil
          end

          inserted = ::Review.insert_all([review_attributes(review, row, fallback_created_at)],
            unique_by: :index_reviews_on_user_and_reviewable, returning: %w[id])
          inserted.rows.first&.first
        end
      end
    end
  end
end
