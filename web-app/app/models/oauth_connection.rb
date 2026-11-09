# frozen_string_literal: true

# A member's approval of one client (OauthApplication) for one resource (the
# MCP endpoint). Tokens and grants hang off it: revoking the connection ends
# every token the client holds. One row per (user, client, resource); approving
# again resets it (Services::Oauth::Connections.approve).
# == Schema Information
#
# Table name: oauth_connections
#
#  id                   :bigint           not null, primary key
#  approved_at          :datetime         not null
#  last_used_at         :datetime
#  resource             :string           not null
#  revoked_at           :datetime
#  scopes               :string           default([]), not null, is an Array
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  oauth_application_id :bigint           not null
#  user_id              :bigint           not null
#
# Indexes
#
#  index_oauth_connections_on_oauth_application_id  (oauth_application_id)
#  index_oauth_connections_on_user_app_resource     (user_id,oauth_application_id,resource) UNIQUE
#  index_oauth_connections_on_user_id               (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (oauth_application_id => oauth_applications.id)
#  fk_rails_...  (user_id => users.id)
#
class OauthConnection < ApplicationRecord
  belongs_to :user
  belongs_to :application, class_name: "OauthApplication", foreign_key: :oauth_application_id,
    inverse_of: :connections
  has_many :access_tokens, class_name: "OauthAccessToken", foreign_key: :connection_id,
    inverse_of: :connection, dependent: :delete_all
  has_many :access_grants, class_name: "OauthAccessGrant", foreign_key: :connection_id,
    inverse_of: :connection, dependent: :delete_all

  validates :resource, inclusion: {in: ->(_) { ::Oauth::Resources.keys }}
  validates :approved_at, presence: true

  scope :live, -> { where(revoked_at: nil) }
  # What the "Connected apps" list shows: live ones, newest approval first.
  scope :listed, -> { live.includes(:application).order(approved_at: :desc, id: :desc) }

  def revoked? = revoked_at.present?

  # The hosts the client signs in through, so a member can tell two apps with
  # the same name apart. Hosts only: a loopback client's port is noise.
  def redirect_hosts
    application.redirect_uri.to_s.split.filter_map do |uri|
      URI(uri).host
    rescue URI::InvalidURIError
      nil
    end.uniq
  end
end
