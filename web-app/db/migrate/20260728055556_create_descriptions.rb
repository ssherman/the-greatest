class CreateDescriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :descriptions do |t|
      t.references :describable, polymorphic: true, null: false
      t.integer :kind, null: false, default: 0
      t.string :locale, null: false, default: "en"
      t.integer :source, null: false
      t.string :source_name
      t.text :content, null: false
      t.integer :rank, null: false, default: 0
      t.string :source_url
      t.integer :license
      t.datetime :retrieved_at
      t.timestamps
    end

    # nulls_not_distinct is load-bearing: source_name is NULL on every non-:other row,
    # and Postgres treats NULLs as distinct by default, so without it this index would
    # accept two identical (describable, kind, locale, wikipedia, NULL) rows.
    add_index :descriptions,
      [:describable_type, :describable_id, :kind, :locale, :source, :source_name],
      unique: true, nulls_not_distinct: true,
      name: "index_descriptions_on_describable_and_key"

    add_check_constraint :descriptions,
      "source <> 9 OR source_name IS NOT NULL",
      name: "descriptions_other_requires_source_name"
  end
end
