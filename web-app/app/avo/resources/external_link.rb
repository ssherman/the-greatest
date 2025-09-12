class Avo::Resources::ExternalLink < Avo::BaseResource
  self.includes = [:submitted_by]

  self.search = {
    query: -> { query.ransack(name_cont: q, url_cont: q, m: "or").result(distinct: false) }
  }

  def fields
    field :id, as: :id
    field :name, as: :text, required: true
    field :description, as: :textarea, hide_on: [:index]
    field :url, as: :text, required: true, format_using: -> do
      if value.present?
        link_to value, value, target: "_blank", class: "text-blue-600 underline"
      else
        value
      end
    end
    field :source, as: :select, enum: ::ExternalLink.sources, required: true
    field :source_name, as: :text
    field :link_category, as: :select, enum: ::ExternalLink.link_categories, required: true
    field :parent, as: :belongs_to, polymorphic_as: :parent, types: [
      ::Music::Artist, ::Music::Album, ::Music::Song, ::Music::Release
    ], required: true
    field :submitted_by, as: :belongs_to, class_name: "User", foreign_key: :submitted_by_id
    field :price_cents, as: :number, help: "Price in cents (e.g., 1299 for $12.99)", hide_on: [:index]
    field :display_price, as: :text, only_on: [:show, :index], format_using: -> { record&.display_price }
    field :public, as: :boolean, required: true
    field :click_count, as: :number, readonly: true, format_using: -> do
      content_tag :span, value, class: "font-mono text-green-600"
    end
    field :source_display_name, as: :text, only_on: [:show, :index], format_using: -> { record&.source_display_name }
    field :metadata, as: :code, language: "json", hide_on: [:index], help: "JSON metadata for API responses and additional context"
    field :created_at, as: :date_time, readonly: true, hide_on: [:new, :edit]
    field :updated_at, as: :date_time, readonly: true, hide_on: [:new, :edit, :index]
  end
end
