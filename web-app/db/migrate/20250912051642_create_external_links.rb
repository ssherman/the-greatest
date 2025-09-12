class CreateExternalLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :external_links do |t|
      t.string :name, null: false
      t.text :description
      t.string :url, null: false
      t.integer :price_cents
      t.integer :source
      t.string :source_name
      t.integer :link_category
      t.references :parent, polymorphic: true, null: false
      t.references :submitted_by, null: true, foreign_key: {to_table: :users}
      t.boolean :public, default: true, null: false
      t.integer :click_count, default: 0, null: false
      t.jsonb :metadata, default: "{}"

      t.timestamps
    end

    add_index :external_links, [:parent_type, :parent_id]
    add_index :external_links, :source
    add_index :external_links, :public
    add_index :external_links, :click_count, order: :desc
  end
end
