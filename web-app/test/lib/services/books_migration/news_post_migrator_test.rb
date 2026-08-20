require "test_helper"

module Services
  module BooksMigration
    class NewsPostMigratorTest < ActiveSupport::TestCase
      def legacy_post(id:, title:, slug:, created_at: 2.years.ago)
        stub(
          id: id,
          title: title,
          slug: slug,
          created_at: created_at,
          updated_at: created_at,
          user_id: users(:admin_user).id,
          body_html: "<div>Body of #{title}</div>"
        )
      end

      test "creates a books news post per legacy post" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Welcome", slug: "welcome")
        ])

        assert_difference -> { ::NewsPost.books.count }, 1 do
          NewsPostMigrator.call
        end

        post = ::NewsPost.books.find_by(slug: "welcome")
        assert_equal "Welcome", post.title
        assert_equal users(:admin_user).id, post.user_id
      end

      test "preserves the legacy slug verbatim, including a collision suffix" do
        weird = "added-5-new-lists-d0171449-5fc7-4e93-b5ea-81e3fac28ce3"
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 12, title: "Added 5 new lists", slug: weird)
        ])

        NewsPostMigrator.call

        assert ::NewsPost.books.exists?(slug: weird)
      end

      test "sets published_at from the legacy created_at" do
        created = Time.zone.parse("2024-05-09 03:48:34")
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 11, title: "300 Lists!", slug: "300-lists", created_at: created)
        ])

        NewsPostMigrator.call

        assert_equal created, ::NewsPost.books.find_by(slug: "300-lists").published_at
      end

      test "stores Markdown, not HTML" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          stub(id: 1, title: "T", slug: "t", created_at: 1.year.ago, updated_at: 1.year.ago,
            user_id: users(:admin_user).id, body_html: "<div><strong>bold</strong></div>")
        ])

        NewsPostMigrator.call

        body = ::NewsPost.books.find_by(slug: "t").body
        assert_includes body, "**bold**"
        assert_not_includes body, "<strong>"
      end

      test "is idempotent -- a second run creates nothing" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Welcome", slug: "welcome")
        ])
        NewsPostMigrator.call

        assert_no_difference -> { ::NewsPost.count } do
          NewsPostMigrator.call
        end
      end

      test "reports round-trip failures without aborting the run" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Good", slug: "good"),
          legacy_post(id: 2, title: "Bad", slug: "bad")
        ])
        NewsBodyConverter.stubs(:round_trips?).returns(true).then.returns(false)

        result = NewsPostMigrator.call

        assert result.success?
        assert_equal [2], result.data[:round_trip_failures]
        assert_equal 2, result.data[:created]
      end

      test "does not migrate the tags, pinned or front_page columns" do
        # They are dropped on purpose: tags is empty on all 31, pinned is false
        # on all 31, and front_page is read by no legacy code.
        assert_not ::NewsPost.column_names.include?("tags")
        assert_not ::NewsPost.column_names.include?("pinned")
        assert_not ::NewsPost.column_names.include?("front_page")
      end
    end
  end
end
