class CreateRecommendationItemNeighbors < ActiveRecord::Migration[8.1]
  def change
    create_table :recommendation_item_neighbors do |t|
      t.references :recommendation_model, null: false, foreign_key: true, index: false
      t.bigint :item_id, null: false
      t.bigint :neighbor_id, null: false
      t.float :weight, null: false
    end
    add_index :recommendation_item_neighbors, [:recommendation_model_id, :item_id]
  end
end
