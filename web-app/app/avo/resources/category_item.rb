class Avo::Resources::CategoryItem < Avo::BaseResource
  self.title = -> { "#{record.category&.name} → #{record.item&.title || record.item&.name}" }
  self.description = "Join table connecting categories to items (albums, songs, artists, movies, etc.)"

  def fields
    field :id, as: :id
    field :category, as: :belongs_to, required: true
    field :item_type, as: :text, readonly: true
    field :item_id, as: :number, readonly: true
    field :item, as: :text, readonly: true,
      format_using: -> {
        if record.item.respond_to?(:title)
          "#{record.item.title} (#{record.item_type})"
        elsif record.item.respond_to?(:name)
          "#{record.item.name} (#{record.item_type})"
        else
          "#{record.item_type} ##{record.item_id}"
        end
      }

    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end

  def filters
    filter :item_type, ::CategoryItem.distinct.pluck(:item_type).compact.map { |t| [t, t] }.to_h
  end
end
