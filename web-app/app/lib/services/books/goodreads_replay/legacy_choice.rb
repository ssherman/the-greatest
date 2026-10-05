# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # The book legacy chose for a user's row (Goodreads import spec §12.4):
      # the one that holds the row's Goodreads id and is on that user's lists.
      # Legacy stamped the id on whatever it picked, so this is its choice. The
      # id may be in slug form (32076670-ball-lightning) until the fix-ups are
      # applied; those 543 rows are read once and cached briefly, rather than
      # pattern-scanned per row.
      class LegacyChoice
        TYPE = "books_work_goodreads_id"
        SLUG_CACHE_KEY = "goodreads_replay:slug_goodreads_holders"

        def self.call(goodreads_book_id:, user_id:)
          id = goodreads_book_id.to_s
          holder_ids = (::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE, value: id).pluck(:identifiable_id) +
            slug_holders.fetch(id, [])).uniq
          return nil if holder_ids.empty?

          book_id = ::UserListItem.joins(:user_list).where(user_lists: {user_id: user_id})
            .where(listable_type: "Books::Book", listable_id: holder_ids).minimum(:listable_id)
          book_id && ::Books::Book.find_by(id: book_id)
        end

        # {"32076670" => [book_id, ...]} for every slug-form Goodreads id.
        def self.slug_holders
          Rails.cache.fetch(SLUG_CACHE_KEY, expires_in: 10.minutes) do
            ::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE).where("value !~ '^[0-9]+$'")
              .pluck(:value, :identifiable_id)
              .group_by { |value, _| value[/\A\d+/] }.except(nil)
              .transform_values { |pairs| pairs.map(&:last) }
          end
        end
      end
    end
  end
end
