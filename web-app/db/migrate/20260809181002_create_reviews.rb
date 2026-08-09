class CreateReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :reviews do |t|
      # index: false -- the composite unique index below and the [user_id, created_at]
      # index both lead with user_id, so a standalone user_id index is redundant.
      t.references :user, null: false, foreign_key: true, index: false
      t.references :reviewable, polymorphic: true, null: false
      t.string :title
      t.text :body
      t.integer :rating, null: false

      t.timestamps
    end

    # One review per user per item. Also the ON CONFLICT arbiter candidate for the
    # increment-2 migrator -- see that plan, which must use an UNTARGETED
    # ON CONFLICT DO NOTHING because preserved ids make the primary key a second
    # colliding constraint.
    add_index :reviews, [:user_id, :reviewable_type, :reviewable_id],
      unique: true, name: "index_reviews_on_user_and_reviewable"

    # A SECOND index on the same columns, alongside the full one that
    # `t.references :reviewable, polymorphic: true` already created above. Both are
    # justified, not redundant: the full index serves `book.reviews` and the
    # recalculator's `GROUP BY`, while this partial one serves the book page's list of
    # reviews that have text (12.6% of rows) at a fraction of the full index's size.
    add_index :reviews, [:reviewable_type, :reviewable_id],
      where: "body IS NOT NULL", name: "index_reviews_on_reviewable_with_body"

    # /my/reviews default sort (increment 5).
    add_index :reviews, [:user_id, :created_at]

    add_check_constraint :reviews, "rating BETWEEN 1 AND 5", name: "reviews_rating_range"

    # Legacy stored 5,177 empty-string bodies that slipped through
    # `where.not(body: nil)` and rendered as blank review cards. This makes an empty
    # body unrepresentable, so `with_body` means what it says. Multi-arg btrim because
    # single-arg btrim only trims ASCII spaces, leaving "\t\n" satisfying the check
    # while being .blank? in Ruby.
    add_check_constraint :reviews,
      "body IS NULL OR length(btrim(body, E' \\t\\n\\r\\f\\v')) > 0",
      name: "reviews_body_not_blank"
  end
end
