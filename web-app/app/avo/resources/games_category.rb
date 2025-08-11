class Avo::Resources::GamesCategory < Avo::BaseResource
  self.title = :name
  self.description = "Games-specific categories for video games and interactive entertainment"
  self.model_class = ::Games::Category

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
    field :parent, as: :belongs_to, class_name: "Games::Category"

    # Games-specific associations (commented until Games::Game model exists)
    # field :games, as: :has_many, through: :category_items

    # Child categories
    field :child_categories, as: :has_many, class_name: "Games::Category"

    # Join table
    field :category_items, as: :has_many
  end

  def filters
    filter :category_type, ::Category.category_types
    filter :import_source, ::Category.import_sources
    filter :deleted, {active: false, deleted: true}
  end
end
