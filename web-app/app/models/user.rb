# == Schema Information
#
# Table name: users
#
#  id                     :bigint           not null, primary key
#  auth_data              :jsonb
#  auth_uid               :string
#  confirmation_sent_at   :datetime
#  confirmation_token     :string
#  confirmed_at           :datetime
#  display_name           :string
#  email                  :string
#  email_verified         :boolean          default(FALSE), not null
#  external_provider      :integer
#  last_sign_in_at        :datetime
#  name                   :string
#  original_signup_domain :string
#  photo_url              :string
#  provider_data          :text
#  role                   :integer          default("user"), not null
#  sign_in_count          :integer
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  stripe_customer_id     :string
#
# Indexes
#
#  index_users_on_auth_uid            (auth_uid)
#  index_users_on_confirmation_token  (confirmation_token) UNIQUE
#  index_users_on_confirmed_at        (confirmed_at)
#  index_users_on_external_provider   (external_provider)
#  index_users_on_stripe_customer_id  (stripe_customer_id)
#
class User < ApplicationRecord
  serialize :provider_data, coder: JSON

  # Associations
  has_many :ranking_configurations, dependent: :destroy
  has_many :penalties, dependent: :destroy
  has_many :ai_chats, dependent: :destroy
  has_many :submitted_lists, class_name: "List", foreign_key: :submitted_by_id, dependent: :nullify
  has_many :submitted_external_links, class_name: "ExternalLink", foreign_key: :submitted_by_id, dependent: :nullify
  has_many :domain_roles, dependent: :destroy
  has_many :user_lists, dependent: :destroy
  has_many :user_list_items, through: :user_lists

  enum :role, [:user, :admin, :editor]
  enum :external_provider, [:facebook, :twitter, :google, :apple, :password]

  after_create :create_default_user_lists

  validates :email, presence: true, uniqueness: true
  validates :role, presence: true
  validates :email_verified, inclusion: {in: [true, false]}
  validates :confirmation_token, uniqueness: true, allow_nil: true

  def default_user_list_for(user_list_class, list_type)
    user_list_class.where(user: self).find_by(list_type: list_type)
  end

  # Email confirmation methods
  def confirmed?
    confirmed_at.present?
  end

  def confirm_email!
    update!(
      confirmed_at: Time.current,
      confirmation_token: nil,
      email_verified: true
    )
  end

  def generate_confirmation_token!
    update!(
      confirmation_token: SecureRandom.urlsafe_base64(32),
      confirmation_sent_at: Time.current
    )
  end

  def confirmation_token_expired?
    return false if confirmation_sent_at.nil?

    confirmation_sent_at < 24.hours.ago
  end

  # Domain-scoped authorization methods

  # Returns DomainRole for the given domain, or nil
  def domain_role_for(domain)
    domain_roles.find_by(domain: domain)
  end

  # Check if user has any access to domain
  def can_access_domain?(domain)
    return true if admin? # global admin bypasses
    domain_role_for(domain).present?
  end

  # Permission level checks for a domain
  def can_read_in_domain?(domain)
    return true if admin?
    domain_role_for(domain)&.can_read? || false
  end

  def can_write_in_domain?(domain)
    return true if admin?
    domain_role_for(domain)&.can_write? || false
  end

  def can_delete_in_domain?(domain)
    return true if admin?
    domain_role_for(domain)&.can_delete? || false
  end

  def can_manage_domain?(domain)
    return true if admin?
    domain_role_for(domain)&.can_manage? || false
  end

  # Get permission level name for display
  def domain_permission_level(domain)
    return :super_admin if admin?
    domain_role_for(domain)&.permission_level&.to_sym
  end

  private

  def create_default_user_lists
    UserList.default_subclasses.each do |klass|
      klass.default_list_types.each do |list_type|
        klass.find_or_create_by!(user: self, list_type: list_type) do |list|
          list.name = klass.default_list_name_for(list_type)
        end
      end
    end
  end
end
