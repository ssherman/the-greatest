class Avo::Resources::GamesPenalty < Avo::BaseResource
  self.title = :name
  self.description = "Game-specific penalties that only apply to game lists and configurations"
  self.model_class = ::Games::Penalty

  def fields
    field :id, as: :id
    field :name, as: :text
    field :description, as: :textarea
    field :user, as: :belongs_to, readonly: true
    field :dynamic_type, as: :select, enum: ::Penalty.dynamic_types
    field :penalty_applications, as: :has_many
    field :lists, as: :has_many, through: :list_penalties
  end
end
