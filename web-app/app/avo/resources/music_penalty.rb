class Avo::Resources::MusicPenalty < Avo::BaseResource
  self.title = :name
  self.description = "Music-specific penalties that only apply to music lists and configurations"
  self.model_class = ::Music::Penalty

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
