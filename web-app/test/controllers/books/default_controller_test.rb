require "test_helper"

module Books
  class DefaultControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
    end

    test "should get rankings page" do
      get books_rankings_url
      assert_response :success
    end

    test "rankings page has a title" do
      get books_rankings_url
      assert_select "title"
    end

    test "rankings page has a meta description" do
      get books_rankings_url
      assert_select "meta[name='description']"
    end

    test "rankings page does not trap links in a turbo frame" do
      assert_no_frame_trapped_links books_rankings_path
    end

    test "rankings page query count does not grow with the number of penalties" do
      get books_rankings_url # warm any per-process memoization

      baseline = count_queries { get books_rankings_url }

      extra = Penalty.create!(type: "Books::Penalty", name: "Extra", category: :list_integrity,
        description: "Added to prove the page does not query per penalty.")
      PenaltyApplication.create!(penalty: extra, ranking_configuration: ranking_configurations(:books_global), value: 5)

      assert_equal baseline, count_queries { get books_rankings_url }
    end

    private

    def count_queries(&block)
      count = 0
      counter = ->(_name, _start, _finish, _id, payload) {
        count += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION])
      }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
  end
end
