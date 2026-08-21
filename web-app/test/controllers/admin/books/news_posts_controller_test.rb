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

      test "preview renders Markdown through the public renderer" do
        post preview_admin_books_news_posts_path,
          params: {news_post: {body: "# Heading\n\nSome **bold** text."}},
          as: :turbo_stream

        assert_response :success
        assert_includes response.body, "<h2>Heading</h2>"
        assert_includes response.body, "<strong>bold</strong>"
      end

      # The only assertion the plan gave this test is a negative
      # (assert_not_includes "<script>alert"), which a 404, a 500, a redirect or
      # an empty body would all satisfy just as well as a correctly-rendered
      # preview -- see task-11-brief.md's own R11 precedent and
      # task-12-brief.md correction 3. assert_response :success closes that
      # gap.
      #
      # The brief also asks for a positive assertion that "alert('x')" survives
      # as inert text. It does not, for this exact input, and that is NOT a bug
      # to fix here -- see the task-12-report.md finding. `<script>...</script>`
      # on a line by itself is a CommonMark "HTML block" (type 1: starts with
      # `<script`, runs to the matching close tag), and BodyRenderer's
      # unsafe: false replaces the ENTIRE block -- open tag, enclosed text, and
      # close tag together -- with one `<!-- raw HTML omitted -->` comment,
      # which the sanitizer then strips. Verified directly against
      # Services::News::BodyRenderer on this branch:
      #   BodyRenderer.call("<script>alert('x')</script>") == "\n"
      # The enclosed text "alert('x')" is gone, not preserved as inert text.
      # (An inline script tag surrounded by ordinary prose behaves differently
      # -- CommonMark treats the tags as inline raw HTML spans and leaves the
      # text between them alone -- but that is a different input than the one
      # this test, and the brief's correction, specify.) Services::News::BodyRenderer
      # is explicitly out of scope for this task, so this assertion is not added.
      test "preview escapes raw HTML exactly as the public page does" do
        post preview_admin_books_news_posts_path,
          params: {news_post: {body: "<script>alert('x')</script>"}},
          as: :turbo_stream

        assert_response :success
        assert_not_includes response.body, "<script>alert"
      end

      # The standalone-input test above pins the security property (the tag
      # never renders) but, per task-12-report.md finding 1, cannot also pin
      # the authoring property for that same input -- CommonMark's HTML-block
      # rule elides a line that STARTS with raw HTML whole, tags and enclosed
      # text together, so "alert('x')" does not survive
      # "<script>alert('x')</script>" alone. Placing the same tag inline
      # inside ordinary prose exercises CommonMark's OTHER raw-HTML rule
      # instead (inline raw HTML spans), where only the tags themselves are
      # elided and surrounding text is untouched -- so this is the input that
      # actually lets the security and authoring properties be asserted
      # separately, which is the established shape on this branch (ledger
      # R11: an earlier implementer reconfigured the sanitizer to prune text
      # and made a test pass by destroying content).
      test "preview escapes an inline script tag while keeping the surrounding words" do
        post preview_admin_books_news_posts_path,
          params: {news_post: {body: "before <script>alert('x')</script> after"}},
          as: :turbo_stream

        assert_response :success
        assert_not_includes response.body, "<script"
        assert_includes response.body, "alert('x')"
      end

      test "preview replaces the preview frame" do
        post preview_admin_books_news_posts_path,
          params: {news_post: {body: "hi"}},
          as: :turbo_stream

        assert_includes response.body, 'target="news_post_preview"'
      end

      # A bare assert_response :success does not distinguish "rendered an empty
      # preview correctly" from "returned 200 having rendered something else"
      # (task-12-brief.md correction 4) -- the same trap assert_empty and a
      # bare assert_response :success are called out for project-wide. Checking
      # the turbo-stream actually targeted the preview region closes that gap.
      test "preview handles an empty body" do
        post preview_admin_books_news_posts_path, params: {news_post: {body: ""}}, as: :turbo_stream

        assert_response :success
        assert_includes response.body, 'target="news_post_preview"'
      end

      # require_domain_write!'s :only list is an allowlist: forgetting to name
      # :preview there does not fail loudly, it just leaves the endpoint
      # reachable by any domain user with read-only access (task-12-brief.md
      # correction 2).
      test "preview is refused for a domain user without write access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        post preview_admin_books_news_posts_path,
          params: {news_post: {body: "hi"}}, as: :turbo_stream

        assert_redirected_to books_root_path
      end

      test "create attaches a share image" do
        post admin_books_news_posts_path, params: {
          news_post: {
            title: "With Image", body: "x",
            share_image: fixture_file_upload("test_image.png", "image/png")
          }
        }

        assert_predicate NewsPost.books.find_by(slug: "with-image").share_image, :attached?
      end

      test "create attaches body images" do
        post admin_books_news_posts_path, params: {
          news_post: {
            title: "With Body Images", body: "x",
            body_images: [fixture_file_upload("test_image.png", "image/png")]
          }
        }

        assert_equal 1, NewsPost.books.find_by(slug: "with-body-images").body_images.count
      end

      test "update adds a body image without replacing the existing ones" do
        post_record = news_posts(:books_december_update)
        post_record.body_images.attach(io: File.open(file_fixture("test_image.png")), filename: "a.png")

        patch admin_books_news_post_path(post_record), params: {
          news_post: {
            title: post_record.title, body: post_record.body,
            body_images: [fixture_file_upload("test_image.png", "image/png")]
          }
        }

        assert_equal 2, post_record.reload.body_images.count
      end

      test "the edit form shows the Markdown snippet for each body image" do
        post_record = news_posts(:books_december_update)
        post_record.body_images.attach(io: File.open(file_fixture("test_image.png")), filename: "cover.png")

        get edit_admin_books_news_post_path(post_record)

        assert_response :success
        assert_includes response.body, "![cover.png]("
      end

      # Defect 1 (task-13b-brief.md): _form.html.erb guarded the share_image
      # preview on `attached?`, which is true for a pending, unsaved
      # attachment. On a validation failure the view then called url_for on a
      # variant of a blob with no id, raising instead of re-rendering the
      # form. Measured before the fix:
      #   ActionView::Template::Error: Cannot get a signed_id for a new record
      test "create re-renders the form instead of raising when an invalid submission carries a share image" do
        post admin_books_news_posts_path, params: {
          news_post: {
            title: "", body: "x",
            share_image: fixture_file_upload("test_image.png", "image/png")
          }
        }

        assert_response :unprocessable_entity
      end

      test "update re-renders the form instead of raising when a replacement share image fails validation on a post that already has one" do
        post_record = news_posts(:books_december_update)
        post_record.share_image.attach(io: File.open(file_fixture("test_image.png")), filename: "existing.png")

        patch admin_books_news_post_path(post_record), params: {
          news_post: {
            title: "", body: post_record.body,
            share_image: fixture_file_upload("test_image.png", "image/png")
          }
        }

        assert_response :unprocessable_entity
      end

      # Defect 2 (task-13b-brief.md): update called attach_body_images BEFORE
      # @news_post.update(news_post_params). At that point the record is
      # freshly loaded with no dirty attributes, so
      # has_many_attached#attach's "persisted and unchanged" branch saves the
      # attachment immediately -- ahead of, and regardless of, the validated
      # save that follows. Measured before the fix:
      #   status=422  images_before=0  images_after=1  title="December Update"
      # The status alone does not catch this -- assert the count.
      test "update rejects an invalid submission without persisting the uploaded body image" do
        post_record = news_posts(:books_december_update)
        images_before = post_record.body_images.count

        patch admin_books_news_post_path(post_record), params: {
          news_post: {
            title: "", body: post_record.body,
            body_images: [fixture_file_upload("test_image.png", "image/png")]
          }
        }

        assert_response :unprocessable_entity
        assert_equal images_before, post_record.reload.body_images.count
      end

      # Fix round 1 finding: the fix above works today, but only because it
      # relies on assign_attributes leaving the record dirty whenever the
      # submission is invalid -- true only because NewsPost currently
      # validates presence on title/body alone. A plain HTTP-level test
      # cannot construct "invalid but not dirtying title/body" against
      # today's validations, so it cannot distinguish "checks valid? before
      # attaching" from "happens to skip the eager-attach save because
      # assign_attributes left the record dirty." Forcing valid? to false
      # via a stub, independent of what was actually submitted, stands in
      # for a hypothetical future validation (e.g. body_images content-type)
      # that would NOT dirty any column and so would NOT be caught by a
      # changed?-based ordering. This pins the actual guarantee: attach is
      # never reached once the record is known invalid, regardless of why.
      test "update never attempts to attach body images once the record is known invalid, independent of which validation trips (pinned via stub)" do
        post_record = news_posts(:books_december_update)
        images_before = post_record.body_images.count

        NewsPost.any_instance.stubs(:valid?).returns(false)
        ActiveStorage::Attached::Many.any_instance.expects(:attach).never

        patch admin_books_news_post_path(post_record), params: {
          news_post: {
            title: post_record.title, body: post_record.body,
            body_images: [fixture_file_upload("test_image.png", "image/png")]
          }
        }

        assert_response :unprocessable_entity
        assert_equal images_before, post_record.reload.body_images.count
      end

      # Defect 3: destroy is implemented, routed and tested, but no view
      # renders a control that hits it.
      test "index renders a delete control for a user who can delete" do
        get admin_books_news_posts_path

        assert_select "form[action=?]", admin_books_news_post_path(news_posts(:books_december_update))
      end

      test "index hides the delete control for a domain user without delete access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        get admin_books_news_posts_path

        assert_select "form[action=?]", admin_books_news_post_path(news_posts(:books_december_update)), count: 0
      end

      # Defect 4: require_domain_write!'s :only list omitted :new and :edit,
      # so a read-only domain viewer could open the full authoring form.
      test "new redirects a domain user without write access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        get new_admin_books_news_post_path

        assert_redirected_to books_root_path
      end

      test "edit redirects a domain user without write access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        get edit_admin_books_news_post_path(news_posts(:books_december_update))

        assert_redirected_to books_root_path
      end

      test "index does not render the New Post link for a domain user without write access" do
        regular_user = users(:regular_user)
        regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(regular_user, stub_auth: true)

        get admin_books_news_posts_path

        assert_select "a", text: "New Post", count: 0
      end
    end
  end
end
