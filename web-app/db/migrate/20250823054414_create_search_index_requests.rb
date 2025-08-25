class CreateSearchIndexRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :search_index_requests do |t|
      t.references :parent, polymorphic: true, null: false
      t.integer :action, null: false

      t.timestamps
    end

    add_index :search_index_requests, [:parent_type, :parent_id]
    add_index :search_index_requests, :action
    add_index :search_index_requests, :created_at
  end
end
