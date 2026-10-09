module Services
  module BooksMigration
    # Every legacy query a sync plan needs, in one place so tests can swap in a
    # fake (no test database has the legacy tables). Exercised for real by the dev
    # rehearsal (spec §9).
    class LegacySource
      def book_rows_above(id) = rows_above(LegacyBooks::Book, id)

      def author_rows_above(id) = rows_above(LegacyBooks::Author, id)

      def book_identifier_rows_above(id) = rows_above(LegacyBooks::BookIdentifier, id)

      def book_ids = LegacyBooks::Book.pluck(:id)

      def author_ids = LegacyBooks::Author.pluck(:id)

      def category_ids = LegacyBooks::Category.pluck(:id)

      def books_updated_since(time, through_id:)
        LegacyBooks::Book.where("id <= ? AND updated_at > ?", through_id, time).count
      end

      def max_book_identifier_id = LegacyBooks::BookIdentifier.maximum(:id).to_i

      private

      def rows_above(model, id)
        model.where("id > ?", id).order(:id).pluck(:id, :created_at)
      end
    end
  end
end
