class Avo::Resources::BooksCategory < Avo::BaseResource
  self.title = :name
  self.description = "Books-specific categories for literature and publications"
  self.model_class = ::Books::Category

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
    field :parent, as: :belongs_to, class_name: "Books::Category"

    # Books-specific associations (commented until Books::Book model exists)
    # field :books, as: :has_many, through: :category_items

    # Child categories
    field :child_categories, as: :has_many, class_name: "Books::Category"

    # Join table
    field :category_items, as: :has_many
  end

  def filters
    filter :category_type, ::Category.category_types
    filter :import_source, ::Category.import_sources
    filter :deleted, {active: false, deleted: true}
  end
end
