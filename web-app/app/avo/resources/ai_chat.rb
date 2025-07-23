class Avo::Resources::AiChat < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :chat_type, as: :select, options: ::AiChat.chat_types
    field :model, as: :text
    field :provider, as: :select, options: ::AiChat.providers
    field :temperature, as: :number
    field :json_mode, as: :boolean
    field :response_schema, as: :code
    field :messages, as: :code
    field :raw_responses, as: :code
    field :parent, as: :belongs_to, readonly: true
    field :user, as: :belongs_to, readonly: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
