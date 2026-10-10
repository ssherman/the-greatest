class CreateRecommendationModels < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendation_models do |t|
      t.string :domain, null: false
      t.string :version, null: false
      t.jsonb :manifest, null: false, default: {}
      t.integer :state, null: false, default: 0
      t.timestamps
    end
    add_index :recommendation_models, [:domain, :version], unique: true
    add_index :recommendation_models, [:domain, :state]
  end
end
