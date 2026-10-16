class AddStagesToBooksVerifications < ActiveRecord::Migration[8.1]
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
  end
end
