require "test_helper"

module Api
  module V1
    module Admin
      module Books
        class NewsPostsControllerTest < ActionDispatch::IntegrationTest
          include SqlCapture

          setup do
            host! "dev-new.thegreatestbooks.org"
            # Sidekiq runs inline and this machine's .env can hold a real
            # Cloudflare token; no endpoint here purges, but a post written
            # through a service in a later test must not reach the network.
            @original_purge_token = ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"]
            ENV.delete("CLOUDFLARE_CACHE_PURGE_TOKEN")
          end

          teardown do
            ENV["CLOUDFLARE_CACHE_PURGE_TOKEN"] = @original_purge_token
          end

          def json = response.parsed_body.deep_symbolize_keys

          def get_json(path, token: ApiTokenSecrets::ADMIN_READ)
            get path, headers: bearer(token)
          end

          def count_queries(&block) = capture_sql(&block).size

          test "the index lists every status and no other site's posts" do
            get_json "/api/v1/admin/news_posts"
            assert_api_response_conform(status: 200, api: :admin)
            ids = json[:data].map { |row| row[:id] }
            assert_equal ::NewsPost.books.ids.sort, ids.sort
            assert_not_includes ids, news_posts(:music_launch).id
          end

          # Dates disagree with ids on purpose: the published posts are created
          # oldest-id-first but newest-date-first, and two drafts tie on date.
          test "the index orders drafts, then scheduled, then published newest first" do
            news_posts(:books_december_update).update_columns(published_at: nil)
            newest, middle, oldest = [1, 2, 4].map.with_index do |days, i|
              ::NewsPost.create!(domain: :books, title: "Published #{i}", body: "x", user: users(:admin_user), published_at: days.days.ago)
            end
            drafts = [news_posts(:books_draft), news_posts(:books_december_update)].sort_by(&:id).reverse

            get_json "/api/v1/admin/news_posts"

            expected = drafts + [news_posts(:books_scheduled), newest, middle, oldest]
            assert_equal expected.map(&:id), json[:data].map { |row| row[:id] }
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

          test "paging links keep the status filter" do
            get_json "/api/v1/admin/news_posts?status=published&per_page=1"

            assert_includes json.dig(:links, :self), "status=published"
          end

          test "times are UTC with microseconds" do
            post = news_posts(:books_december_update)
            post.update_columns(published_at: Time.utc(2026, 1, 2, 3, 4, 5, 123_456))
            get_json "/api/v1/admin/news_posts?status=published"

            row = json[:data].find { |r| r[:id] == post.id }
            post.reload
            assert_equal "2026-01-02T03:04:05.123456Z", row[:published_at]
            assert_equal post.created_at.utc.iso8601(6), row[:created_at]
            assert_equal post.updated_at.utc.iso8601(6), row[:updated_at]
          end

          test "a post with attachments reports them, and one without reports none" do
            with = news_posts(:books_december_update)
            with.share_image.attach(io: File.open(file_fixture("test_image.png")), filename: "share.png")
            with.body_images.attach(io: File.open(file_fixture("test_image.png")), filename: "inline.png")
            get_json "/api/v1/admin/news_posts"

            rows = json[:data].index_by { |row| row[:id] }
            assert_equal [true, 1], [rows[with.id][:has_share_image], rows[with.id][:body_images_count]]
            bare = rows[news_posts(:books_draft).id]
            assert_equal [false, 0], [bare[:has_share_image], bare[:body_images_count]]
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

          test "topics lists this site's topics by name with their post counts, every status counted" do
            news_posts(:books_draft).news_topics << news_topics(:books_rankings)
            get_json "/api/v1/admin/news_topics"
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal ["Feature Launch", "New Lists", "Rankings"], json[:data].map { |row| row[:name] }
            counts = json[:data].to_h { |row| [row[:slug], row[:posts_count]] }
            assert_equal({"feature-launch" => 0, "new-lists" => 0, "rankings" => 2}, counts)
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
