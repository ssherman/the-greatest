require "test_helper"

module Services
  class PageContentTest < ActiveSupport::TestCase
    PAGE = <<~HTML
      <!DOCTYPE html>
      <html><head><title>Best Books</title><style>.x{color:red}</style><script>var tracking = 1;</script></head>
      <body class="home"><!-- BEGIN WAYBACK TOOLBAR INSERT -->
      <div id="wm-ipp-base" lang="en"><div id="wm-ipp">Wayback toolbar text</div></div>
      <!-- END WAYBACK TOOLBAR INSERT -->
      <div id="content" class="main">
        <h2 class="title">Top   Novels</h2>
        <p>Intro   paragraph.</p>
        <ol><li><a href="/war" class="l">War and Peace</a></li><li>Ulysses</li></ol>
        <table><tr><td>1</td><td>Voter One</td></tr></table>
      </div></body></html>
    HTML

    def call(format, html = PAGE) = PageContent.call(html: html, format: format)

    test "the Wayback toolbar is removed in every format" do
      %w[simplified text html].each do |format|
        content = call(format).data[:content]

        assert_not_includes content, "Wayback toolbar text", format
        assert_not_includes content, "WAYBACK TOOLBAR", format
        assert_not_includes content, "wm-ipp", format
        assert_includes content, "Ulysses", format
      end
    end

    test "simplified keeps structure and links but drops attributes, scripts and styles" do
      content = call("simplified").data[:content]

      assert_includes content, "<table>"
      assert_includes content, "<ol>"
      assert_includes content, "<h2>"
      assert_includes content, '<a href="/war">'
      assert_no_match(/\sclass=|\sid=/, content)
      assert_not_includes content, "<script"
      assert_not_includes content, "<style"
      assert_not_includes content, "tracking"
      assert_includes content, "Top Novels"
      assert_no_match(/ {2,}/, content)
    end

    test "text puts block elements on separate lines and has no tags" do
      content = call("text").data[:content]
      lines = content.lines.map(&:strip)

      assert_no_match(/<[a-z]/i, content)
      assert_includes lines, "Top Novels"
      assert_includes lines, "Intro paragraph."
      assert_includes lines, "Ulysses"
      assert_not_includes content, "tracking"
      assert_no_match(/\n{3,}/, content)
    end

    test "html keeps the markup minus the toolbar" do
      content = call("html").data[:content]

      assert_includes content, 'class="main"'
      assert_includes content, '<a href="/war" class="l">'
    end

    test "simplified and text are capped at 100,000 characters, html at 200,000" do
      assert_equal({"simplified" => 100_000, "text" => 100_000, "html" => 200_000}, PageContent::CAPS)

      big = "<html><body><p>" + ("word " * 60_000) + "</p></body></html>"
      %w[simplified text html].each do |format|
        data = call(format, big).data

        assert_equal PageContent::CAPS[format], data[:content].length, format
        assert data[:truncated], format
        assert_operator data[:length], :>, PageContent::CAPS[format], format
      end
    end

    test "a page under the cap is not truncated and reports its length" do
      data = call("text").data

      assert_equal false, data[:truncated]
      assert_equal data[:content].length, data[:length]
    end

    test "a multibyte string is cut on a character boundary" do
      big = "<html><body><p>" + ("é" * 150_000) + "</p></body></html>"
      data = call("text", big).data

      assert_equal 100_000, data[:content].length
      assert data[:content].valid_encoding?
      assert data[:truncated]
    end

    test "an unknown format fails" do
      result = call("pdf")

      assert_not result.success?
      assert_match(/format/, result.errors.join)
    end
  end
end
