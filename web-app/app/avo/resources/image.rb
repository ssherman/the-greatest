class Avo::Resources::Image < Avo::BaseResource
  self.includes = [:parent]

  def fields
    field :id, as: :id
    field :file, as: :file, is_image: true
    field :parent, as: :belongs_to, polymorphic_as: :parent, types: [::Music::Artist, ::Music::Album, ::Music::Release]
    field :primary, as: :boolean, help: "Mark as the primary image for ranking views"
    field :notes, as: :textarea
    field :analyzed, as: :boolean, readonly: true
    field :identified, as: :boolean, readonly: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
