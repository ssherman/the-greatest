require "test_helper"

module Services
  module BooksMigration
    class NewsConversionReportTest < ActiveSupport::TestCase
      def legacy_post(id:, title:, slug:, body_html:)
        stub(id: id, title: title, slug: slug, body_html: body_html)
      end

      test "writes legacy HTML, converted Markdown and a round-trips line per post" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 1, title: "Welcome", slug: "welcome",
            body_html: "<div><strong>bold</strong></div>")
        ])
        path = Rails.root.join("tmp", "news_conversion_report_test_#{SecureRandom.hex(4)}.txt")

        result = NewsConversionReport.call(path: path)

        assert_equal path, result
        contents = File.read(path)
        assert_includes contents, "#1  Welcome  (welcome)"
        assert_includes contents, "round-trips: true"
        assert_includes contents, "<div><strong>bold</strong></div>"
        assert_includes contents, "**bold**"
      ensure
        FileUtils.rm_f(path)
      end

      test "reports round-trips: false for a post that does not round-trip" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 2, title: "Odd", slug: "odd", body_html: "<div>x</div>")
        ])
        NewsBodyConverter.stubs(:round_trips?).returns(false)
        path = Rails.root.join("tmp", "news_conversion_report_test_#{SecureRandom.hex(4)}.txt")

        NewsConversionReport.call(path: path)

        assert_includes File.read(path), "round-trips: false"
      ensure
        FileUtils.rm_f(path)
      end

      test "defaults to tmp/news_posts_conversion.txt when no path is given" do
        ::LegacyBooks::BlogPost.stubs(:order).returns([
          legacy_post(id: 3, title: "Def", slug: "def", body_html: "<div>y</div>")
        ])

        result = NewsConversionReport.call

        assert_equal Rails.root.join("tmp", "news_posts_conversion.txt"), result
      ensure
        FileUtils.rm_f(Rails.root.join("tmp", "news_posts_conversion.txt"))
      end
    end
  end
end
