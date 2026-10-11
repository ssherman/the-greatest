class AllowFractionalReviewRatings < ActiveRecord::Migration[8.1]
  # Goodreads rates in quarter stars since 2026-10-05, and its export writes
  # "3.75" (and "4.0" for a whole star). Every existing rating is an integer
  # 1..5, which satisfies the new range, so nothing is rewritten beyond the
  # type change. Only books has reviews, and books has not launched.
  #
  # No quarter-step constraint on purpose: the five-bar rounding and the star
  # display work for any decimal, so a stray 3.3 from an import is just 3.3.
  def up
    remove_check_constraint :reviews, name: "reviews_rating_range"
    change_column :reviews, :rating, :decimal, precision: 3, scale: 2
    add_check_constraint :reviews, "rating > 0 AND rating <= 5", name: "reviews_rating_range"

    change_column :review_summaries, :ratings_sum, :decimal, precision: 10, scale: 2, default: 0, null: false
    change_column :books_goodreads_import_rows, :rating, :decimal, precision: 3, scale: 2
  end

  # Refuses rather than truncating: a fractional rating cast back to integer
  # would silently lose what the reader entered.
  def down
    fractional = select_value("SELECT COUNT(*) FROM reviews WHERE rating <> TRUNC(rating)").to_i +
      select_value("SELECT COUNT(*) FROM books_goodreads_import_rows WHERE rating <> TRUNC(rating)").to_i
    raise ActiveRecord::IrreversibleMigration, "#{fractional} fractional ratings would be truncated" if fractional.positive?

    remove_check_constraint :reviews, name: "reviews_rating_range"
    change_column :reviews, :rating, :integer
    add_check_constraint :reviews, "rating >= 1 AND rating <= 5", name: "reviews_rating_range"

    change_column :review_summaries, :ratings_sum, :integer, default: 0, null: false
    change_column :books_goodreads_import_rows, :rating, :integer
  end
end
