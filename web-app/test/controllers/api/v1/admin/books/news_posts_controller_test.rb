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
            # Cloudflare token; the create and update endpoints enqueue a purge,
            # which must not reach the network.
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

          # -- create and update ----------------------------------------

          def send_json(method, path, body = nil, token: ApiTokenSecrets::ADMIN)
            public_send(method, path, params: body, as: :json, headers: bearer(token))
          end

          # books:admin:write and nothing more: proves that scope alone is enough.
          def write_token
            @write_token ||= Services::Api::Tokens.generate(
              user: users(:admin_user), name: "write", scopes: ["books:admin:write"], expires_at: 1.day.from_now
            ).data[:secret]
          end

          # The purge jobs a block enqueues, with nothing run.
          def purges
            ::Sidekiq::Testing.fake! do
              ::News::PurgeCachedPagesJob.jobs.clear
              yield
              ::News::PurgeCachedPagesJob.jobs.dup
            end
          end

          test "create makes a draft owned by the token's user, with the body exactly as sent" do
            body = "  Line one\r\nLine two  \n"
            send_json :post, "/api/v1/admin/news_posts", {title: "  Fresh News ", body: body, summary: " ", topic_ids: [news_topics(:books_rankings).id] * 2}, token: write_token
            assert_api_response_conform(status: 201, api: :admin)
            post = NewsPost.find(json.dig(:data, :id))
            assert_equal ["Fresh News", body, "books", users(:admin_user), "draft"], [post.title, post.body, post.domain, post.user, post.status]
            assert_nil post.summary
            assert_equal [news_topics(:books_rankings).id], post.news_topic_ids
            get "/news/#{post.slug}"
            assert_response :not_found
          end

          test "create enqueues a purge" do
            jobs = purges { send_json :post, "/api/v1/admin/news_posts", {title: "Fresh", body: "x"} }
            assert_equal 1, jobs.size
          end

          test "a taken title is a 409 naming the post that has it" do
            assert_no_difference("NewsPost.count") { send_json :post, "/api/v1/admin/news_posts", {title: "December Update", body: "x"} }
            assert_api_response_conform(status: 409, api: :admin)
            existing = news_posts(:books_december_update)
            assert_includes json[:detail], existing.id.to_s
            assert_includes json[:detail], existing.title
            assert_includes json[:detail], existing.status
          end

          test "a retried create makes one post" do
            2.times { send_json :post, "/api/v1/admin/news_posts", {title: "Once Only", body: "x"} }
            assert_response :conflict
            assert_equal 1, NewsPost.books.where(title: "Once Only").count
          end

          BAD_CREATES = {
            400 => [{title: "T"}, {body: "x"}, {title: 5, body: "x"}, {title: "T", body: ["x"]}, {title: "T", body: "a\u0000b"},
              {title: "T", body: "x", summary: 1}, {title: "T", body: "x", topic_ids: "1"}, {title: "T", body: "x", topic_ids: ["1"]},
              {title: nil, body: "x"}, {title: "T", body: nil}, {title: "T", body: "x", topic_ids: nil}, {title: "T", body: "x", topic_ids: [true]},
              {title: "T", body: "x", topic_ids: [1.0]}, {title: "T\u0000", body: "x"}, {title: "T", body: "x", summary: "s\u0000"}],
            422 => [{title: " ", body: "x"}, {title: "T", body: " \n"}, {title: "T" * 201, body: "x"}, {title: "T", body: "x" * 100_001},
              {title: "T", body: "x", summary: "s" * 501}, {title: "T", body: "x", published_at: "2030-01-01T00:00:00Z"},
              {title: "T", body: "x", topic_ids: [2**70]}, {title: "日本語", body: "x"}, {title: "Topic", body: "x"}]
          }.freeze

          test "bad creates are refused and write nothing" do
            BAD_CREATES.each do |status, bodies|
              bodies.each do |body|
                assert_no_difference("NewsPost.count") { send_json :post, "/api/v1/admin/news_posts", body }
                assert_equal [status, body.inspect.first(60)], [response.status, body.inspect.first(60)]
              end
            end
          end

          test "another site's topic is a 422 on create and update" do
            foreign = news_topics(:music_site_news).id
            assert_no_difference("NewsPost.count") { send_json :post, "/api/v1/admin/news_posts", {title: "T", body: "x", topic_ids: [foreign]} }
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], foreign.to_s

            live = news_posts(:books_december_update)
            before = live.news_topic_ids.sort
            send_json :patch, "/api/v1/admin/news_posts/#{live.id}", {topic_ids: [foreign]}
            assert_api_response_conform(status: 422, api: :admin)
            assert_includes json[:detail], foreign.to_s
            assert_equal before, live.reload.news_topic_ids.sort
          end

          test "update edits a live post in place and purges it" do
            post = news_posts(:books_december_update)
            jobs = purges { send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: "Retitled", summary: nil}, token: write_token }
            assert_api_response_conform(status: 200, api: :admin)
            post.reload
            assert_equal ["Retitled", "december-update", "published"], [post.title, post.slug, post.status]
            assert_nil post.summary
            assert_equal %w[summary title], json[:changed].sort
            assert_includes jobs.first["args"].last, "https://dev-new.thegreatestbooks.org/news/december-update"
          end

          test "topic_ids replaces the set and an empty list clears it" do
            post = news_posts(:books_december_update)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {topic_ids: [news_topics(:books_new_lists).id]}, token: write_token
            assert_equal [[news_topics(:books_new_lists).id], ["topic_ids"]], [post.reload.news_topic_ids, json[:changed]]
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {topic_ids: []}
            assert_empty post.reload.news_topic_ids
          end

          test "a body change needs expected_updated_at" do
            post = news_posts(:books_draft)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {body: "new"}
            assert_api_response_conform(status: 400, api: :admin)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {body: "new", expected_updated_at: post.updated_at.utc.iso8601(6)}
            assert_api_response_conform(status: 200, api: :admin)
            assert_equal "new", post.reload.body
          end

          test "an image the admin added after the agent read the post is not overwritten" do
            send_json :post, "/api/v1/admin/news_posts", {title: "With Picture", body: "Words"}
            id, slug, read_at = json[:data].values_at(:id, :slug, :updated_at)
            sign_in_as(users(:admin_user), stub_auth: true)
            patch admin_books_news_post_path(slug), params: {news_post: {title: "With Picture", body: "Words ![p](/p.png)", body_images: [fixture_file_upload("test_image.png", "image/png")]}}

            send_json :patch, "/api/v1/admin/news_posts/#{id}", {body: "Better words", expected_updated_at: read_at}
            assert_api_response_conform(status: 409, api: :admin)
            assert_equal "Words ![p](/p.png)", NewsPost.find(id).body

            get_json "/api/v1/admin/news_posts/#{id}"
            assert_equal 1, json.dig(:data, :body_images_count)
            send_json :patch, "/api/v1/admin/news_posts/#{id}", {body: "Better words ![p](/p.png)", expected_updated_at: json.dig(:data, :updated_at)}
            assert_response :success
          end

          test "a stale expected_updated_at is refused without a body too" do
            post = news_posts(:books_draft)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: "Later", expected_updated_at: 1.day.ago.utc.iso8601(6)}
            assert_response :conflict
            assert_not_equal "Later", post.reload.title
          end

          test "an update with nothing to change, or a bad expected_updated_at, is a 400" do
            id = news_posts(:books_draft).id
            now = news_posts(:books_draft).updated_at.utc.iso8601(6)
            [{}, {expected_updated_at: now}, {title: "T", expected_updated_at: "yesterday"}, {title: "T", expected_updated_at: "2026-02-30T00:00:00Z"},
              {title: "T", expected_updated_at: "2026-01-01T00:00:00+99:00"}, {title: "T", expected_updated_at: 5}].each do |body|
              send_json :patch, "/api/v1/admin/news_posts/#{id}", body
              assert_equal [400, body.inspect], [response.status, body.inspect]
            end
            assert_not_equal "T", news_posts(:books_draft).reload.title
          end

          test "an update with a blank title, a blank body or an unknown key is a 422 and writes nothing" do
            post = news_posts(:books_draft)
            stamp = post.updated_at.utc.iso8601(6)
            [{title: " "}, {body: " ", expected_updated_at: stamp}, {title: "T", slug: "x"}, {title: "T", published_at: "2030-01-01T00:00:00Z"}].each do |body|
              send_json :patch, "/api/v1/admin/news_posts/#{post.id}", body
              assert_equal [422, body.inspect], [response.status, body.inspect]
            end
            assert_equal ["Something Unfinished", "Not ready yet.", "something-unfinished"], [post.reload.title, post.body, post.slug]
          end

          test "a failed update leaves the topics unchanged" do
            post = news_posts(:books_december_update)
            before = post.news_topic_ids.sort
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: " ", topic_ids: [news_topics(:books_new_lists).id]}
            assert_response :unprocessable_content
            assert_equal before, post.reload.news_topic_ids.sort
          end

          test "another site's post is a 404 on update" do
            send_json :patch, "/api/v1/admin/news_posts/#{news_posts(:music_launch).id}", {title: "T"}
            assert_response :not_found
          end

          test "a read token cannot create or update" do
            assert_no_difference("NewsPost.count") { send_json :post, "/api/v1/admin/news_posts", {title: "T", body: "x"}, token: ApiTokenSecrets::ADMIN_READ }
            assert_api_response_conform(status: 403, api: :admin)
            send_json :patch, "/api/v1/admin/news_posts/#{news_posts(:books_draft).id}", {title: "T"}, token: ApiTokenSecrets::ADMIN_READ
            assert_api_response_conform(status: 403, api: :admin)
            assert_not_equal "T", news_posts(:books_draft).reload.title
          end

          test "a user the policy refuses gets a 403 and nothing is written" do
            NewsPostPolicy.any_instance.stubs(:create?).returns(false)
            NewsPostPolicy.any_instance.stubs(:update?).returns(false)
            assert_no_difference("NewsPost.count") { send_json :post, "/api/v1/admin/news_posts", {title: "Denied", body: "x"} }
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
            send_json :patch, "/api/v1/admin/news_posts/#{news_posts(:books_draft).id}", {title: "Denied"}
            assert_api_response_conform(status: 403, api: :admin)
            assert_equal "forbidden", json[:code]
            assert_not_equal "Denied", news_posts(:books_draft).reload.title
          end

          test "a books editor with only the write scope can create and update" do
            editor = users(:regular_user)
            DomainRole.create!(user: editor, domain: :books, permission_level: :editor)
            secret = Services::Api::Tokens.generate(user: editor, name: "editor", scopes: ["books:admin:write"], expires_at: 1.day.from_now).data[:secret]

            send_json :post, "/api/v1/admin/news_posts", {title: "Editor Post", body: "x"}, token: secret
            assert_api_response_conform(status: 201, api: :admin)
            id = json.dig(:data, :id)
            assert_equal editor, NewsPost.find(id).user
            send_json :patch, "/api/v1/admin/news_posts/#{id}", {title: "Editor Post Two"}, token: secret
            assert_api_response_conform(status: 200, api: :admin)
          end

          test "a null expected_updated_at is a 400 and writes nothing" do
            post = news_posts(:books_draft)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {body: "x", expected_updated_at: nil}
            assert_api_response_conform(status: 400, api: :admin)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: "T", expected_updated_at: nil}
            assert_api_response_conform(status: 400, api: :admin)
            assert_equal ["Something Unfinished", "Not ready yet."], [post.reload.title, post.body]
          end

          test "create and update each log one line without the text sent" do
            lines = []
            Rails.logger.stubs(:info).with { |line| lines << line.to_s }
            send_json :post, "/api/v1/admin/news_posts", {title: "Secret Title", body: "Secret body text", summary: "Secret summary"}
            id = json.dig(:data, :id)
            send_json :patch, "/api/v1/admin/news_posts/#{id}", {title: "Secret Title Two", summary: "Secret summary two"}

            ours = lines.grep(/event=api_admin_news_post/)
            assert_equal 2, ours.size
            token = ApiToken.find_by!(token_prefix: ApiTokenSecrets::ADMIN[0, 12])
            assert_match(/action=create changed= token_id=#{token.id} token_kind=\w+ user_id=#{token.user_id} news_post_id=#{id}\z/, ours.first)
            assert_match(/action=update changed=title,summary token_id=#{token.id} token_kind=\w+ user_id=#{token.user_id} news_post_id=#{id}\z/, ours.last)
            ours.each { |line| assert_no_match(/secret/i, line) }
          end

          test "changed lists only the fields that differ" do
            post = news_posts(:books_december_update)
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: "Different", summary: post.summary, topic_ids: post.news_topic_ids}
            assert_equal ["title"], json[:changed]
            send_json :patch, "/api/v1/admin/news_posts/#{post.id}", {title: "Different", summary: "New summary"}
            assert_equal ["summary"], json[:changed]
          end

          test "values at exactly the limits are accepted" do
            send_json :post, "/api/v1/admin/news_posts", {title: "T" * 200, body: "b" * 100_000, summary: "s" * 500}
            assert_api_response_conform(status: 201, api: :admin)
            assert_equal [200, 100_000, 500], json[:data].values_at(:title, :body, :summary).map(&:length)
          end

          test "a summary is stripped" do
            send_json :post, "/api/v1/admin/news_posts", {title: "Stripped Summary", body: "x", summary: "  Padded  "}
            assert_equal "Padded", json.dig(:data, :summary)
          end
        end
      end
    end
  end
end
