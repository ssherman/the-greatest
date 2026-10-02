class CreateCsvExports < ActiveRecord::Migration[8.1]
  def change
    create_table :csv_exports do |t|
      # One export per configuration (spec §6): the unique index is the invariant.
      t.references :ranking_configuration, null: false, foreign_key: true, index: {unique: true}
      t.integer :status, null: false, default: 0
      t.datetime :requested_at
      t.datetime :generated_at
      t.integer :row_count
      t.bigint :byte_size
      t.text :error_message

      t.timestamps
    end
  end
end
