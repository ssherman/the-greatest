require "test_helper"

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
class OauthApplicationTest < ActiveSupport::TestCase
  test "the fixtures are valid public clients" do
    OauthApplication.all.each do |application|
      assert application.valid?, application.errors.full_messages.to_sentence
      assert_not application.confidential?
      assert_nil application.secret
    end
  end

  test "destroying an application removes its connections" do
    application = oauth_applications(:claude_code)

    assert_difference "OauthConnection.count", -1 do
      application.destroy!
    end
  end
end
