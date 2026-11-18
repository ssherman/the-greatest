class CreateBooksPublisherIntakeRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :books_publisher_intake_runs do |t|
      t.string :source, null: false
      t.integer :kind, default: 0, null: false
      t.integer :status, default: 0, null: false
      t.boolean :baseline, default: false, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.text :error
      t.jsonb :counts, default: {}, null: false

      t.timestamps
    end
    add_index :books_publisher_intake_runs, [:source, :started_at]
  end
end
