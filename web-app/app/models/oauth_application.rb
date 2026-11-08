# frozen_string_literal: true

# An OAuth client (Claude, Claude Code, Codex...), created by dynamic client
# registration. Always public: no secret, PKCE instead.
# == Schema Information
#
# Table name: oauth_applications
#
#  id           :bigint           not null, primary key
#  confidential :boolean          default(TRUE), not null
#  name         :string           not null
#  redirect_uri :text             not null
#  scopes       :string           default(""), not null
#  secret       :string
#  uid          :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_oauth_applications_on_uid  (uid) UNIQUE
#
class OauthApplication < ApplicationRecord
  include ::Doorkeeper::Orm::ActiveRecord::Mixins::Application

  has_many :connections, class_name: "OauthConnection", foreign_key: :oauth_application_id,
    inverse_of: :application, dependent: :destroy
end
