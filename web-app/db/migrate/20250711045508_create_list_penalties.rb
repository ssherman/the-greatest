class CreateListPenalties < ActiveRecord::Migration[8.0]
  def change
    create_table :list_penalties do |t|
      t.references :list, null: false, foreign_key: true
      t.references :penalty, null: false, foreign_key: true

      t.timestamps
    end

    add_index :list_penalties, [:list_id, :penalty_id], unique: true, name: "index_list_penalties_on_list_and_penalty"
  end
end
