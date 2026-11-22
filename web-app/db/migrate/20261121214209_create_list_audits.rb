class CreateListAudits < ActiveRecord::Migration[8.1]
  def change
    create_table :list_audits do |t|
      t.references :list, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: {on_delete: :nullify}
      t.integer :status, null: false, default: 0
      t.integer :verdict
      t.datetime :lease_expires_at
      t.datetime :started_at
      t.datetime :finished_at
      t.jsonb :before
      t.jsonb :after
      t.jsonb :field_changes
      t.text :note
      t.jsonb :sources, null: false, default: []

      t.timestamps
    end

    add_index :list_audits, :list_id, unique: true, where: "status = 0",
      name: "index_list_audits_one_open_per_list"
    add_index :list_audits, [:status, :finished_at]
  end
end
