class CreateCorrections < ActiveRecord::Migration[8.1]
  def change
    create_table :corrections do |t|
      t.references :correctable, polymorphic: true, null: false
      t.references :user, null: true, foreign_key: true
      t.references :resolved_by, null: true, foreign_key: {to_table: :users}
      t.text :notes
      t.integer :status, null: false, default: 0
      t.datetime :resolved_at
      t.text :resolution_notes
      t.string :submitter_ip

      t.timestamps
    end

    # Backs the admin queue: "pending corrections for this domain's types,
    # newest first" is every index page load.
    add_index :corrections, [:status, :created_at]
  end
end
