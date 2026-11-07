require "test_helper"

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
class OauthConnectionTest < ActiveSupport::TestCase
  setup do
    @connection = oauth_connections(:member_mcp)
  end

  test "the fixture is valid" do
    assert @connection.valid?
  end

  test "resource must be a known one" do
    @connection.resource = "rest"
    assert_not @connection.valid?
    assert_includes @connection.errors[:resource], "is not included in the list"
  end

  test "one connection per user, client and resource" do
    duplicate = OauthConnection.new(
      user: @connection.user, application: @connection.application, resource: "mcp",
      scopes: [], approved_at: Time.current
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "live excludes revoked connections and revoked? reports them" do
    assert_not @connection.revoked?
    assert_includes OauthConnection.live, @connection

    @connection.update!(revoked_at: Time.current)

    assert @connection.revoked?
    assert_not_includes OauthConnection.live, @connection
  end

  test "destroying a connection deletes its tokens and grants" do
    issue_oauth_token(@connection)
    OauthAccessGrant.create!(
      application: @connection.application, resource_owner_id: @connection.user_id,
      connection_id: @connection.id, token: "grant-secret", expires_in: 600,
      redirect_uri: "http://localhost/callback"
    )

    @connection.destroy!

    assert_empty OauthAccessToken.where(connection_id: @connection.id)
    assert_empty OauthAccessGrant.where(connection_id: @connection.id)
  end
end
