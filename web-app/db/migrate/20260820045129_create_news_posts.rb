class CreateNewsPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :news_posts do |t|
      t.integer :domain, null: false
      t.string :title, null: false
      t.string :slug, null: false
      t.text :body, null: false
      t.text :summary
      t.datetime :published_at
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :news_posts, [:domain, :slug], unique: true
    add_index :news_posts, [:domain, :published_at], order: {published_at: :desc}
  end
end
