class User < ApplicationRecord
  serialize :provider_data, coder: JSON

  enum :role, [:user, :admin, :editor]
  enum :external_provider, [:facebook, :twitter, :google, :apple, :password]

  validates :email, presence: true, uniqueness: true
  validates :role, presence: true
  validates :email_verified, inclusion: {in: [true, false]}
end
