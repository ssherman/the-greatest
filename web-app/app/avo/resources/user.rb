class Avo::Resources::User < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :auth_uid, as: :text
    field :auth_data, as: :code
    field :email, as: :text
    field :display_name, as: :text
    field :name, as: :text
    field :photo_url, as: :text
    field :original_signup_domain, as: :text
    field :role, as: :number
    field :external_provider, as: :number
    field :email_verified, as: :boolean
    field :last_sign_in_at, as: :date_time
    field :sign_in_count, as: :number
    field :provider_data, as: :textarea
    field :stripe_customer_id, as: :text
  end
end
