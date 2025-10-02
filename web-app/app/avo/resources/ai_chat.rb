class Avo::Resources::AiChat < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::AiChat
  self.title = :id

  # Make AI chats read-only - no creation via AVO
  self.find_record_method = -> {
    if id.present?
      query.find(id)
    else
      # Prevent creation by returning empty relation
      query.none
    end
  }

  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id, readonly: true
    field :chat_type, as: :select, enum: ::AiChat.chat_types, readonly: true
    field :model, as: :text, readonly: true
    field :provider, as: :select, enum: ::AiChat.providers, readonly: true
    field :temperature, as: :number, readonly: true
    field :json_mode, as: :boolean, readonly: true
    field :parameters, as: :code, format: :json, pretty_generated: true, height: "300px", readonly: true
    field :response_schema, as: :code, format: :json, pretty_generated: true, height: "400px", readonly: true
    field :messages, as: :code, format: :json, pretty_generated: true, height: "600px", readonly: true
    field :raw_responses, as: :code, format: :json, pretty_generated: true, height: "400px", readonly: true
    field :parent,
      as: :belongs_to,
      polymorphic_as: :parent,
      types: [::List, ::Music::Artist, ::Music::Album, ::Music::Song, ::Category, ::Movies::Movie],
      readonly: true
    field :user, as: :belongs_to, readonly: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end

  def actions
    # No actions - read-only interface
  end
end
