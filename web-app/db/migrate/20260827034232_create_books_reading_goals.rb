class CreateBooksReadingGoals < ActiveRecord::Migration[8.0]
  def change
    create_table :books_reading_goals do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :target_count, null: false
      t.date :starts_on, null: false
      t.date :ends_on, null: false
      t.boolean :public, null: false, default: false

      t.timestamps
    end

    add_check_constraint :books_reading_goals, "target_count > 0",
      name: "books_reading_goals_target_count_positive"
    add_check_constraint :books_reading_goals, "ends_on >= starts_on",
      name: "books_reading_goals_dates_ordered"
    add_index :books_reading_goals, [:user_id, :public, :starts_on, :ends_on],
      name: "index_books_reading_goals_for_public_date_lookup"

    reversible do |direction|
      direction.up do
        execute <<~SQL
          SELECT setval(
            pg_get_serial_sequence('books_reading_goals', 'id'),
            10000,
            false
          )
        SQL
      end
    end
  end
end
