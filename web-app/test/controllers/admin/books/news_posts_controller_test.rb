require "test_helper"

module Admin
  module Books
    class NewsPostsControllerTest < ActionDispatch::IntegrationTest
      setup do
        host! "dev-new.thegreatestbooks.org"
        sign_in_as(users(:admin_user), stub_auth: true)
      end

      test "index lists this domain's posts, drafts included" do
        get admin_books_news_posts_path

        assert_response :success
        ids = @controller.view_assigns["news_posts"].map(&:id)
        assert_includes ids, news_posts(:books_december_update).id
        assert_includes ids, news_posts(:books_draft).id
      end

      test "index excludes another domain's posts" do
        get admin_books_news_posts_path

        assert_not_includes @controller.view_assigns["news_posts"].map(&:id),
          news_posts(:music_launch).id
      end

      # The plain fixtures alone cannot discriminate published_at-order from
      # id-order: hashed fixture ids happen to fall in the same relative order
      # as the intended publish order (see task-10-brief.md, correction 2). So
      # this test builds two extra published books posts IN the test, where the
      # one created FIRST (lower id, because Rails resets the pk sequence above
      # every fixture id after loading fixtures on Postgres) is published LATER.
      # Under `published_at DESC NULLS FIRST, id DESC` the two sort by publish
      # date; under plain `id DESC` they sort in the opposite order AND the
      # draft is no longer first, because both new rows outrank it on id. So the
      # full expected sequence discriminates the ordering twice over.
      test "index orders drafts first, then newest published" do
        published_later = NewsPost.create!(
          domain: :books, title: "Ordering Probe Later", body: "later",
          published_at: 1.day.ago, user: users(:admin_user)
        )
        published_earlier = NewsPost.create!(
          domain: :books, title: "Ordering Probe Earlier", body: "earlier",
          published_at: 2.days.ago, user: users(:admin_user)
        )
        # published_earlier was created AFTER published_later, so it has the
        # higher id despite the earlier publish date.
        assert_operator published_earlier.id, :>, published_later.id

        get admin_books_news_posts_path

        ids = @controller.view_assigns["news_posts"].map(&:id)
        # books_scheduled's published_at is 7 days FROM NOW, which is the
        # largest timestamp of all -- it sorts ahead of the in-test posts too.
        expected = [
          news_posts(:books_draft).id,
          news_posts(:books_scheduled).id,
          published_later.id,
          published_earlier.id,
          news_posts(:books_december_update).id
        ]
        assert_equal expected, ids
      end

      test "show renders a post" do
        get admin_books_news_post_path(news_posts(:books_december_update))

        assert_response :success
        assert_select "h1", text: /December Update/
      end

      test "show renders a draft" do
        get admin_books_news_post_path(news_posts(:books_draft))

        assert_response :success
      end

      test "show 404s for another domain's post" do
        get admin_books_news_post_path(news_posts(:music_launch))

        assert_response :not_found
      end

      test "create makes a draft when no publish date is given" do
        assert_difference -> { NewsPost.books.count }, 1 do
          post admin_books_news_posts_path, params: {
            news_post: {title: "Brand New", body: "Hello **world**.", published_at: ""}
          }
        end

        created = NewsPost.books.find_by(slug: "brand-new")
        assert_nil created.published_at
        assert_predicate created, :draft?
        assert_equal users(:admin_user).id, created.user_id
      end

      test "create stores the body exactly as typed" do
        markdown = "# Heading\n\nSome **bold** text.\n"

        post admin_books_news_posts_path, params: {news_post: {title: "Verbatim", body: markdown}}

        assert_equal markdown, NewsPost.books.find_by(slug: "verbatim").body
      end

      test "create attaches the selected topics" do
        post admin_books_news_posts_path, params: {
          news_post: {
            title: "Tagged", body: "x",
            news_topic_ids: [news_topics(:books_rankings).id, news_topics(:books_new_lists).id]
          }
        }

        assert_equal [news_topics(:books_new_lists).id, news_topics(:books_rankings).id].sort,
          NewsPost.books.find_by(slug: "tagged").news_topic_ids.sort
      end

      # assert_empty would also pass if topic assignment were broken entirely
      # (see task-11-brief.md, correction 3), which is a different failure with
      # the same signature. Submitting one topic from each domain and asserting
      # the exact surviving id list discriminates "drops nothing" from "drops
      # everything" with a single assertion.
      test "create refuses a topic belonging to another domain" do
        post admin_books_news_posts_path, params: {
          news_post: {
            title: "Cross", body: "x",
            news_topic_ids: [news_topics(:books_rankings).id, news_topics(:music_site_news).id]
          }
        }

        assert_equal [news_topics(:books_rankings).id],
          NewsPost.books.find_by(slug: "cross").news_topic_ids
      end

      test "create re-renders the form with the body intact on a validation failure" do
        post admin_books_news_posts_path, params: {news_post: {title: "", body: "kept text"}}

        assert_response :unprocessable_entity
        assert_includes response.body, "kept text"
      end

      test "update publishes by setting a date" do
        draft = news_posts(:books_draft)

        patch admin_books_news_post_path(draft), params: {
          news_post: {title: draft.title, body: draft.body, published_at: 1.minute.ago.to_fs(:db)}
        }

        assert_predicate draft.reload, :published?
      end

      test "update does not move the slug when the title changes" do
        post_record = news_posts(:books_december_update)

        patch admin_books_news_post_path(post_record), params: {
          news_post: {title: "December Update Revised", body: post_record.body}
        }

        assert_equal "december-update", post_record.reload.slug
      end

      test "destroy removes the post" do
        assert_difference -> { NewsPost.books.count }, -1 do
          delete admin_books_news_post_path(news_posts(:books_draft))
        end
      end

      # NewsPost's friendly_id is scoped to :domain WITHOUT :finders, so a
      # lookup that skips the scope fails open, not closed -- it silently
      # resolves another domain's record instead of raising. Measured on the
      # sibling topics controller last task by mutating set_news_post to a bare
      # NewsPost.friendly.find: edit rendered the other domain's record, update
      # renamed it, and destroy deleted it, with the whole suite green.
      test "edit 404s for another domain's post" do
        get edit_admin_books_news_post_path(news_posts(:music_launch))

        assert_response :not_found
      end

      test "update 404s for another domain's post and leaves it unchanged" do
        post_record = news_posts(:music_launch)

        patch admin_books_news_post_path(post_record), params: {
          news_post: {title: "Hijacked", body: post_record.body}
        }

        assert_response :not_found
        assert_equal "The Greatest Music Is Live", post_record.reload.title
      end

      test "destroy 404s for another domain's post and does not remove it" do
        post_record = news_posts(:music_launch)

        assert_no_difference -> { NewsPost.count } do
          delete admin_books_news_post_path(post_record)
        end

        assert_response :not_found
        assert NewsPost.exists?(post_record.id)
      end

      # require_domain_write! is the only check in the request path that tests
      # WRITE permission -- authenticate_admin! only proves domain access, which
      # a viewer also has. No books-domain read-only user fixture exists (only
      # music_editor/games_viewer, both on contractor_user), so the role is
      # built here rather than added as a fixture, per task-11-brief.md.
      test "create is refused for a domain user without write access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        assert_no_difference -> { NewsPost.books.count } do
          post admin_books_news_posts_path, params: {news_post: {title: "Should Not Exist", body: "x"}}
        end
      end
    end
  end
end
