class CreateReviewSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :review_summaries do |t|
      # index: false -- the unique index below covers the same columns.
      t.references :reviewable, polymorphic: true, null: false, index: false
      t.integer :ratings_count, null: false, default: 0
      t.integer :ratings_sum, null: false, default: 0
      t.integer :text_reviews_count, null: false, default: 0
      t.integer :rating_1_count, null: false, default: 0
      t.integer :rating_2_count, null: false, default: 0
      t.integer :rating_3_count, null: false, default: 0
      t.integer :rating_4_count, null: false, default: 0
      t.integer :rating_5_count, null: false, default: 0

      t.timestamps
    end

    # Unique, and the ON CONFLICT arbiter for SummaryRecalculator's upserts.
    add_index :review_summaries, [:reviewable_type, :reviewable_id],
      unique: true, name: "index_review_summaries_on_reviewable"
  end
end
