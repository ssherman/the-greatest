class Avo::Resources::Category < Avo::BaseResource
  self.title = :name
  self.description = "Base category resource - use specific media type resources for better functionality"

  def fields
    field :id, as: :id
    field :type, as: :text, readonly: true
    field :name, as: :text, required: true
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :category_type, as: :select, enum: ::Category.category_types, required: true
    field :import_source, as: :select, enum: ::Category.import_sources
    field :alternative_names, as: :tags
    field :item_count, as: :number, readonly: true
    field :deleted, as: :boolean
    field :parent, as: :belongs_to, class_name: "Category"

    # Generic associations
    field :child_categories, as: :has_many, class_name: "Category"
    field :category_items, as: :has_many
  end

  def filters
    # Remove problematic filters for now
    # filter :type, ::Category.distinct.pluck(:type).compact.map { |t| [t, t] }.to_h
    # Commenting out problematic enum filters
    # filter :category_type, ::Category.category_types
    # filter :import_source, ::Category.import_sources
    # filter :deleted, {active: false, deleted: true}
  end
end
