class AddManuallyOrderedToUserLists < ActiveRecord::Migration[8.1]
  def change
    # Postgres 11+ adds a NOT NULL column with a constant default without
    # rewriting the table, so this is safe on the ~350k user_lists rows.
    # Backfill is a separate rake task (Services::UserLists::BackfillManuallyOrdered):
    # it only matters for legacy-imported books data, which lives in development
    # only, and keeping it out of the migration keeps every fresh database and
    # test setup from paying for it.
    add_column :user_lists, :manually_ordered, :boolean, default: false, null: false
  end
end
