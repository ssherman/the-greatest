class AddStagesToBooksVerifications < ActiveRecord::Migration[8.1]
  # Where a row that existed before this migration stands, by its work outcome
  # (work_outcome integers: confirmed 0, updated 1, replaced 2, keyed 3,
  # duplicate_pair 4, unsure 5, failed 6, reverted 7, removed 8; stage: work 0,
  # identifiers 1, worldcat 2, signals 3, done 4). Without it every old row
  # defaults to stage work, and VerifyBook would send a settled row to
  # ApplyBook, which skips it, so stages 2-4 would never run for it.
  BACKFILL_STAGE_SQL = <<~SQL.squish
    UPDATE books_verifications SET stage = CASE work_outcome
      WHEN 0 THEN 1 WHEN 1 THEN 1 WHEN 2 THEN 1 WHEN 3 THEN 1
      WHEN 4 THEN 2 WHEN 5 THEN 2 WHEN 8 THEN 2
      WHEN 7 THEN 4
      ELSE 0 END
  SQL

  def change
    change_table :books_verifications, bulk: true do |t|
      t.integer :cohort, null: false, default: 0
      t.integer :stage, null: false, default: 0
      t.text :stage_error
      t.integer :added_count, null: false, default: 0
      t.integer :confirmed_count, null: false, default: 0
      t.integer :candidate_count, null: false, default: 0
      t.integer :wrong_count, null: false, default: 0
      t.boolean :lump_suspect, null: false, default: false
      t.string :worldcat_dump_date
      t.datetime :checked_at
      t.index :stage
      t.index :lump_suspect
    end

    reversible do |dir|
      dir.up { execute BACKFILL_STAGE_SQL }
    end
  end
end
