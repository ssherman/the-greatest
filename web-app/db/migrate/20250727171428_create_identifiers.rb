class CreateIdentifiers < ActiveRecord::Migration[8.0]
  def change
    create_table :identifiers do |t|
      t.references :identifiable, polymorphic: true, null: false
      t.integer :identifier_type, null: false
      t.string :value, null: false

      t.timestamps
    end

    # Primary unique index for specific lookups and uniqueness constraint
    add_index :identifiers, [:identifiable_type, :identifier_type, :value, :identifiable_id],
      unique: true,
      name: "index_identifiers_on_lookup_unique"

    # Secondary index for value-only searches (e.g., finding books by any ISBN format)
    add_index :identifiers, [:identifiable_type, :value],
      name: "index_identifiers_on_type_and_value"
  end
end
