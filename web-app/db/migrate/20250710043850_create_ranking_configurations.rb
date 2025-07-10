class CreateRankingConfigurations < ActiveRecord::Migration[8.0]
  def change
    create_table :ranking_configurations do |t|
      t.string :type, null: false
      t.string :name, null: false
      t.text :description
      t.boolean :global, default: true, null: false
      t.boolean :primary, default: false, null: false
      t.boolean :archived, default: false, null: false
      t.datetime :published_at
      t.integer :algorithm_version, default: 1, null: false
      t.decimal :exponent, precision: 10, scale: 2, default: 3.0, null: false
      t.decimal :bonus_pool_percentage, precision: 10, scale: 2, default: 3.0, null: false
      t.integer :min_list_weight, default: 1, null: false
      t.integer :list_limit
      t.boolean :apply_list_dates_penalty, default: true, null: false
      t.integer :max_list_dates_penalty_age, default: 50
      t.integer :max_list_dates_penalty_percentage, default: 80
      t.boolean :inherit_penalties, default: true, null: false
      t.references :inherited_from, null: true, foreign_key: {to_table: :ranking_configurations}
      t.references :user, null: true, foreign_key: true
      t.references :primary_mapped_list, null: true, foreign_key: {to_table: :lists}
      t.references :secondary_mapped_list, null: true, foreign_key: {to_table: :lists}
      t.integer :primary_mapped_list_cutoff_limit

      t.timestamps
    end

    add_index :ranking_configurations, [:type, :global]
    add_index :ranking_configurations, [:type, :primary]
    add_index :ranking_configurations, [:type, :user_id]
  end
end
