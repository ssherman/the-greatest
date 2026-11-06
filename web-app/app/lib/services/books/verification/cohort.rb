# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 4, amended: legacy book ids are strictly monotonic with
      # created_at, and the first one created on or after the Goodreads
      # imports feature (2024-09-09 03:22:31 UTC) is 16,572 (measured on the
      # legacy database 2026-10-16: no exceptions either side). New-app books
      # start at the reserved ceiling and count as pre_import.
      module Cohort
        module_function

        FIRST_POST_IMPORT_ID = 16_572

        def post_import_range = FIRST_POST_IMPORT_ID...::Services::BooksMigration::RESERVED_CEILINGS.fetch("books_books")

        def for(book_id) = post_import_range.cover?(book_id) ? :post_import : :pre_import
      end
    end
  end
end
