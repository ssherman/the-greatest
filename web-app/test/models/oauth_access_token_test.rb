require "test_helper"

# == Schema Information
#
# Table name: oauth_access_tokens
#
#  id                     :bigint           not null, primary key
#  expires_in             :integer
#  previous_refresh_token :string           default(""), not null
#  refresh_token          :string
#  revoked_at             :datetime
#  scopes                 :string
#  token                  :string           not null
#  created_at             :datetime         not null
#  application_id         :bigint           not null
#  connection_id          :bigint           not null
#  resource_owner_id      :bigint
#
# Indexes
#
#  index_oauth_access_tokens_on_application_id     (application_id)
#  index_oauth_access_tokens_on_connection_id      (connection_id)
#  index_oauth_access_tokens_on_refresh_token      (refresh_token) UNIQUE
#  index_oauth_access_tokens_on_resource_owner_id  (resource_owner_id)
#  index_oauth_access_tokens_on_token              (token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (application_id => oauth_applications.id)
#  fk_rails_...  (connection_id => oauth_connections.id)
#  fk_rails_...  (resource_owner_id => users.id)
#
class OauthAccessTokenTest < ActiveSupport::TestCase
  test "a token is stored hashed and belongs to its connection" do
    connection = oauth_connections(:member_mcp)
    access, refresh = issue_oauth_token(connection)

    token = OauthAccessToken.by_token(access)

    assert_equal connection, token.connection
    assert_not_equal access, token.token
    assert_equal Digest::SHA256.hexdigest(access), token.token
    assert_equal token, OauthAccessToken.by_refresh_token(refresh)
  end

  test "a token without a connection is refused" do
    token = OauthAccessToken.new(application: oauth_applications(:claude_code), resource_owner_id: users(:regular_user).id, scopes: "books:read")
    assert_not token.valid?
    assert token.errors.of_kind?(:connection, :blank)
  end
end
