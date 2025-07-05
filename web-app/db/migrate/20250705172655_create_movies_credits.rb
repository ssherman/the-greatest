class CreateMoviesCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :movies_credits do |t|
      t.references :person, null: false, foreign_key: {to_table: :movies_people}
      t.references :creditable, polymorphic: true, null: false
      t.integer :role, null: false, default: 0
      t.integer :position
      t.string :character_name

      t.timestamps
    end

    # Add indexes as specified in the task document
    add_index :movies_credits, [:creditable_type, :creditable_id]
    add_index :movies_credits, [:person_id, :role]
  end
end
