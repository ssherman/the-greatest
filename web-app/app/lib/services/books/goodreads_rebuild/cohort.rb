# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Which books the rebuild trusts and which it rebuilds from their export
      # rows (docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md §3,
      # §12 call 1). Pre-import and new-app books are trusted by id. A
      # post-import book is trusted when it sits on any list except the
      # generated user-favorites list: Shane put it there by hand and would not
      # have listed an invalid book. Every other post-import book came in
      # through a legacy Goodreads import and is derived.
      #
      # Computed live from list_items, so a book added to a real list becomes
      # trusted with nothing to re-run. Legacy's three favorites lists were not
      # migrated; the new app's generated one is excluded here.
      module Cohort
        module_function

        def post_import_range = ::Services::Books::Verification::Cohort.post_import_range

        def trusted?(book_id)
          return true unless post_import_range.cover?(book_id)

          qualifying_items.exists?(listable_id: book_id)
        end

        def derived = post_import_books.where.not(id: qualifying_items.select(:listable_id))

        def trusted_post_import = post_import_books.where(id: qualifying_items.select(:listable_id))

        def counts
          derived_count = derived.count
          {
            "trusted" => post_import_books.count - derived_count,
            "derived" => derived_count,
            "only_on_user_favorites" => derived.where(id: favorites_items.select(:listable_id)).count
          }
        end

        def post_import_books = ::Books::Book.where(id: post_import_range)

        # auto_generated_kind is NULL on every hand-made list, hence IS DISTINCT FROM.
        def qualifying_items
          book_items.where("lists.auto_generated_kind IS DISTINCT FROM ?", ::List.auto_generated_kinds[:user_favorites])
        end

        def favorites_items = book_items.where(lists: {auto_generated_kind: :user_favorites})

        def book_items = ::ListItem.joins(:list).where(listable_type: "Books::Book")
      end
    end
  end
end
