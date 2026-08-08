class CreateSavedSearches < ActiveRecord::Migration[8.1]
  def change
    create_table :saved_searches do |t|
      t.string :type, null: false
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.text :description
      t.jsonb :criteria, null: false
      t.boolean :public, default: false, null: false
      t.datetime :last_executed_at
      t.integer :result_count

      t.timestamps
    end

    add_index :saved_searches, [:type, :user_id]
    add_index :saved_searches, :public, where: "public = true"
  end
end
