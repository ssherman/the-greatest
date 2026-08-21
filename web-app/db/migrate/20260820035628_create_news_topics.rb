class CreateNewsTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :news_topics do |t|
      t.integer :domain, null: false
      t.string :name, null: false
      t.string :slug, null: false

      t.timestamps
    end

    add_index :news_topics, [:domain, :slug], unique: true
  end
end
