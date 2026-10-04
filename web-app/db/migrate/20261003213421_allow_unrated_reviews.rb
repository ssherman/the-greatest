class AllowUnratedReviews < ActiveRecord::Migration[8.1]
  # Goodreads lets a reader write a review without picking stars. Every existing
  # row has a rating (151,166 of 151,166 in legacy, verified 2026-10-03), so the
  # constraint is satisfied the moment it is added.
  def change
    change_column_null :reviews, :rating, true
    add_check_constraint :reviews, "rating IS NOT NULL OR body IS NOT NULL", name: "reviews_rating_or_body"
  end
end
