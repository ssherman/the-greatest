class Avo::Resources::MusicCredit < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Credit
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :artist, as: :belongs_to
    field :creditable, as: :text
    field :role, as: :select, options: Music::Credit.roles
    field :position, as: :number
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
