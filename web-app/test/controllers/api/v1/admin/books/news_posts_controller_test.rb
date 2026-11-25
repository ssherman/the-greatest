require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class NewsPostsControllerTest < ActionDispatch::IntegrationTest
          include SqlCapture

          setup { host! "dev-new.thegreatestbooks.org" }

          def json = response.parsed_body.deep_symbolize_keys

          def get_json(path, token: ApiTokenSecrets::ADMIN_READ)
            get path, headers: bearer(token)
          end

          def count_queries(&block) = capture_sql(&block).size

          test "the index lists every status, drafts first, and no other site's posts" do
            get_json "/api/v1/admin/news_posts"
            assert_api_response_conform(status: 200, api: :admin)
            ids = json[:data].map { |row| row[:id] }
            assert_equal news_posts(:books_draft).id, ids.first
            assert_equal ::NewsPost.books.ids.sort, ids.sort
            assert_not_includes ids, news_posts(:music_launch).id
          end

          test "status filters, and an unknown one is a 400" do
            {"draft" => :books_draft, "scheduled" => :books_scheduled, "published" => :books_december_update}.each do |status, name|
              get_json "/api/v1/admin/news_posts?status=#{status}"
              assert_equal [status], json[:data].map { |row| row[:status] }.uniq
              assert_includes json[:data].map { |row| row[:id] }, news_posts(name).id
            end
            get_json "/api/v1/admin/news_posts?status=live"
            assert_api_response_conform(status: 400, api: :admin)
          end

          test "a row carries the documented fields and no body" do
            get_json "/api/v1/admin/news_posts?status=published"
            row = json[:data].find { |r| r[:id] == news_posts(:books_december_update).id }
            assert_equal %i[id title slug status published_at url admin_url summary topics has_share_image body_images_count created_at updated_at], row.keys
            assert_equal "https://dev-new.thegreatestbooks.org/news/december-update", row[:url]
            assert_equal [{id: news_topics(:books_rankings).id, name: "Rankings", slug: "rankings"}], row[:topics]
          end

          test "show adds the body, its HTML and an excerpt, with a microsecond updated_at" do
            post = news_posts(:books_december_update)
            post.update!(body: "**bold** <script>x</script>")
            get_json "/api/v1/admin/news_posts/#{post.id}"
            assert_api_response_conform(status: 200, api: :admin)
            data = json[:data]
            assert_equal post.body, data[:body]
            assert_includes data[:body_html], "<strong>bold</strong>"
            assert_not_includes data[:body_html], "<script"
            assert data[:excerpt].present?
            assert_equal post.reload.updated_at.utc.iso8601(6), data[:updated_at]
          end

          test "a draft's show names the address it will have and the admin edit page" do
            get_json "/api/v1/admin/news_posts/#{news_posts(:books_draft).id}"
            assert_equal "https://dev-new.thegreatestbooks.org/news/something-unfinished", json.dig(:data, :url)
            assert_equal "https://dev-new.thegreatestbooks.org/admin/news_posts/something-unfinished/edit", json.dig(:data, :admin_url)
            assert_nil json.dig(:data, :published_at)
          end

          test "another site's post, an unknown id and a slug are 404" do
            [news_posts(:music_launch).id, 999_999_999, "december-update"].each do |id|
              get_json "/api/v1/admin/news_posts/#{id}"
              assert_response :not_found
            end
          end

          test "topics lists this site's topics by name with their post counts" do
            get_json "/api/v1/admin/news_topics"
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["Feature Launch", "New Lists", "Rankings"], json[:data].map { |row| row[:name] }
            assert_equal 1, json[:data].find { |row| row[:slug] == "rankings" }[:posts_count]
          end

          test "the index does not query per post" do
            post = news_posts(:books_draft)
            post.news_topics << news_topics(:books_rankings)
            get_json "/api/v1/admin/news_posts"
            baseline = count_queries { get_json "/api/v1/admin/news_posts" }
            5.times { |i| ::NewsPost.create!(domain: :books, title: "N #{i}", body: "x", user: users(:admin_user)).news_topics << news_topics(:books_rankings) }
            assert_equal baseline, count_queries { get_json "/api/v1/admin/news_posts" }
          end
        end
      end
    end
  end
end
