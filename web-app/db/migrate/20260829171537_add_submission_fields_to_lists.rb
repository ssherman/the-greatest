class AddSubmissionFieldsToLists < ActiveRecord::Migration[8.1]
  def up
    add_column :lists, :submitted_at, :datetime
    add_column :lists, :submitter_email, :string
    add_column :lists, :submitter_ip, :string
    add_index :lists, :submitted_at

    # Backfill the legacy submissions carried over from the old books site so the
    # admin "user submitted" filter finds them. A no-op in production -- all 209
    # such rows are Books::List and books data exists only in development.
    execute <<~SQL
      UPDATE lists SET submitted_at = created_at WHERE submitted_by_id IS NOT NULL
    SQL
  end

  def down
    remove_index :lists, :submitted_at
    remove_column :lists, :submitter_ip
    remove_column :lists, :submitter_email
    remove_column :lists, :submitted_at
  end
end
