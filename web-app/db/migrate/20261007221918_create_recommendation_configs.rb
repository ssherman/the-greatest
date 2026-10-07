class CreateRecommendationConfigs < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendation_configs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :type, null: false
      t.jsonb :criteria, null: false, default: {}
      t.timestamps
    end
    add_index :recommendation_configs, [:user_id, :type], unique: true
  end
end
