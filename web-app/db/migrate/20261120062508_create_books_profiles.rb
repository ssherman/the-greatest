class CreateBooksProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :books_profiles do |t|
      t.references :user, null: false, foreign_key: true, index: {unique: true}
      t.boolean :public, null: false, default: false
      t.string :display_name
      t.boolean :show_stats, null: false, default: false
      t.boolean :show_favorites, null: false, default: false
      t.boolean :show_goals, null: false, default: false
      t.boolean :show_reading_now, null: false, default: false
      t.boolean :show_taste, null: false, default: false
      t.boolean :show_recently_read, null: false, default: false
      t.boolean :show_top_rated, null: false, default: false
      t.boolean :show_reviews, null: false, default: false

      t.timestamps
    end
  end
end
