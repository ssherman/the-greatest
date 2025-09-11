class CreateImages < ActiveRecord::Migration[8.0]
  def change
    create_table :images do |t|
      t.references :parent, polymorphic: true, null: false
      t.text :notes
      t.json :metadata, default: {}

      t.timestamps
    end
  end
end
