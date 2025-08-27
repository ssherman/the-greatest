class Avo::Resources::MusicCategory < Avo::BaseResource
  self.title = :name
  self.description = "Music-specific categories for albums, artists, and songs"
  self.model_class = ::Music::Category

  def fields
    field :id, as: :id
    field :name, as: :text, required: true
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :category_type, as: :select, enum: ::Category.category_types, required: true
    field :import_source, as: :select, enum: ::Category.import_sources
    field :alternative_names, as: :tags
    field :item_count, as: :number, readonly: true
    field :deleted, as: :boolean
    field :parent, as: :belongs_to, class_name: "Music::Category"

    # Music-specific associations
    field :albums, as: :has_many, through: :category_items
    field :artists, as: :has_many, through: :category_items
    field :songs, as: :has_many, through: :category_items

    # Child categories
    field :child_categories, as: :has_many, class_name: "Music::Category"

    # Join table
    field :category_items, as: :has_many
  end

  def filters
    # Commenting out problematic enum filters
    # filter :category_type, ::Category.category_types
    # filter :import_source, ::Category.import_sources
    # filter :deleted, {active: false, deleted: true}
  end
end
