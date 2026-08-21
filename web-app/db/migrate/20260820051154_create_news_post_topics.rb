class CreateNewsPostTopics < ActiveRecord::Migration[8.1]
  def change
    create_table :news_post_topics do |t|
      t.references :news_post, null: false, foreign_key: true
      t.references :news_topic, null: false, foreign_key: true

      t.timestamps
    end

    add_index :news_post_topics, [:news_post_id, :news_topic_id], unique: true
  end
end
