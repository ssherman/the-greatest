# == Schema Information
#
# Table name: recommendation_item_neighbors
#
#  id                      :bigint           not null, primary key
#  weight                  :float            not null
#  item_id                 :bigint           not null
#  neighbor_id             :bigint           not null
#  recommendation_model_id :bigint           not null
#
# Indexes
#
#  idx_on_recommendation_model_id_item_id_65911a84a9  (recommendation_model_id,item_id)
#
# Foreign Keys
#
#  fk_rails_...  (recommendation_model_id => recommendation_models.id)
#
# "A reader who shelved item_id is led to neighbor_id with this weight": one
# row of the trainer's top-k EASE matrix (spec 2 §4.2). No timestamps and no
# item FK on purpose -- a million rows, replaced wholesale on every load.
class RecommendationItemNeighbor < ApplicationRecord
  belongs_to :recommendation_model
end
