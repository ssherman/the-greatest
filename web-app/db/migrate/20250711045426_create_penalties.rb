class CreatePenalties < ActiveRecord::Migration[8.0]
  def change
    create_table :penalties do |t|
      t.string :type, null: false
      t.string :name, null: false
      t.text :description
      t.boolean :global, default: false, null: false
      t.references :user, null: true, foreign_key: true
      t.integer :media_type, default: 0, null: false
      t.boolean :dynamic, default: false, null: false

      t.timestamps
    end

    add_index :penalties, :type
    add_index :penalties, :global
    add_index :penalties, :media_type
    add_index :penalties, :dynamic
  end
end
