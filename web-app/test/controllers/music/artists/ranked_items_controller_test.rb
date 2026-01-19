require "test_helper"

module Music
  module Artists
    class RankedItemsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev.thegreatestmusic.org"
      end

      test "should get index with default global configuration" do
        get "/artists"
        assert_response :success
      end

      test "should get index with page parameter" do
        get "/artists?page=2"
        assert_response :success
      end

      test "should handle missing ranking configuration gracefully" do
        Music::Artists::RankingConfiguration.stubs(:default_primary).returns(nil)

        get "/artists"
        assert_response :success
      end
    end
  end
end
