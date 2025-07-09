class User < ApplicationRecord
  serialize :provider_data, coder: JSON

  enum :role, [:user, :admin, :editor]
  enum :external_provider, [:facebook, :twitter, :google, :apple, :password]

  validates :email, presence: true, uniqueness: true
  validates :role, presence: true
  validates :email_verified, inclusion: {in: [true, false]}
  validates :confirmation_token, uniqueness: true, allow_nil: true

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
end
