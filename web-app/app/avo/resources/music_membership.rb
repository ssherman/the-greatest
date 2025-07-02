class Avo::Resources::MusicMembership < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Membership
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :artist, as: :belongs_to
    field :member, as: :belongs_to
    field :joined_on, as: :date
    field :left_on, as: :date
  end
end
