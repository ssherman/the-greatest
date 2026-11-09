require "test_helper"

module Oauth
  class PruneJobTest < ActiveSupport::TestCase
    test "runs the pruner" do
      app = OauthApplication.create!(name: "Old", redirect_uri: "http://localhost/cb", scopes: "", confidential: false)
      app.update_columns(created_at: 40.days.ago)

      PruneJob.new.perform

      assert_not OauthApplication.exists?(app.id)
    end
  end
end
