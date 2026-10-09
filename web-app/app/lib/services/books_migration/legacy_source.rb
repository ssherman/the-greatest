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

      def user_versions = LegacyBooks::User.pluck(:id, :updated_at).to_h

      def user_list_versions = LegacyBooks::UserList.pluck(:id, :updated_at).to_h

      def saved_search_versions = LegacyBooks::SavedSearch.pluck(:id, :updated_at).to_h

      # Newest first: ReviewMigrator keeps the newer of two reviews that collide.
      def review_rows = LegacyBooks::Review.order(id: :desc).pluck(:id, :user_id, :book_id, :updated_at)

      def correction_rows = LegacyBooks::Changeset.pluck(:id, :changeable_id)

      def reading_goal_ids = LegacyBooks::ReadingGoal.pluck(:id)

      def recommendation_config_count = LegacyBooks::RecommendationConfig.count

      # list id => [item count, md5 of its book ids in id order]. UserDataDiff
      # computes the same here, so only lists that differ are compared item by item.
      def user_list_item_digests
        LegacyBooks::UserListBook.group(:user_list_id)
          .pluck(:user_list_id, Arel.sql("COUNT(*)"), Arel.sql("md5(string_agg(book_id::text, ',' ORDER BY book_id))"))
          .to_h { |list_id, count, digest| [list_id, [count, digest]] }
      end

      def user_list_items_for(list_ids) = LegacyBooks::UserListBook.where(user_list_id: list_ids).map(&:attributes)

      private

      def rows_above(model, id)
        model.where("id > ?", id).order(:id).pluck(:id, :created_at)
      end
    end
  end
end
