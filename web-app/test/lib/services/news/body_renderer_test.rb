require "test_helper"

module Services
  module News
    class BodyRendererTest < ActiveSupport::TestCase
      test ".call returns an empty safe buffer for nil" do
        assert_equal "", BodyRenderer.call(nil)
        assert_predicate BodyRenderer.call(nil), :html_safe?
      end

      test ".call returns an empty safe buffer for blank input" do
        assert_equal "", BodyRenderer.call("   ")
      end

      test ".call renders basic Markdown" do
        html = BodyRenderer.call("Some **bold** and _italic_ text.")

        assert_includes html, "<strong>bold</strong>"
        assert_includes html, "<em>italic</em>"
      end

      test ".call renders links" do
        assert_includes BodyRenderer.call("[a](https://x.test)"), '<a href="https://x.test">a</a>'
      end

      test ".call renders lists" do
        html = BodyRenderer.call("- one\n- two\n")

        assert_includes html, "<ul>"
        assert_includes html, "<li>one</li>"
      end

      test ".call renders tables" do
        assert_includes BodyRenderer.call("A | B\n--- | ---\n1 | 2\n"), "<table>"
      end

      test ".call shifts a level-one heading to h2" do
        # The page title is already the page's h1.
        html = BodyRenderer.call("# Title\n")

        assert_includes html, "<h2>Title</h2>"
        assert_not_includes html, "<h1"
      end

      test ".call shifts h2 to h3 and h3 to h4" do
        html = BodyRenderer.call("## Two\n\n### Three\n")

        assert_includes html, "<h3>Two</h3>"
        assert_includes html, "<h4>Three</h4>"
      end

      test ".call caps the shift at h4" do
        html = BodyRenderer.call("#### Four\n\n##### Five\n\n###### Six\n")

        assert_equal 3, html.scan("<h4>").length
        assert_not_includes html, "<h5"
      end

      test ".call emits no heading anchor links" do
        # commonmarker injects <a href="#slug" class="anchor"></a> into every
        # heading by default. The sanitizer drops class and aria-label but KEEPS
        # href, so without extension: {header_ids: nil} every heading ends up
        # carrying an empty anchor.
        html = BodyRenderer.call("# Title\n")

        assert_not_includes html, "anchor"
        assert_not_includes html, 'href="#'
      end

      test ".call does not render raw HTML from the source" do
        # Pins that a dangerous tag never reaches the output -- by whichever
        # layer catches it. This alone does NOT discriminate unsafe: false from
        # unsafe: true, because commonmarker's tagfilter extension escapes
        # "script" and "iframe" independently of unsafe:. See ".call does not
        # honour raw HTML even when the tag is on the allowlist" below for the
        # test that actually pins unsafe: false.
        html = BodyRenderer.call("before <script>alert('x')</script> after")

        assert_not_includes html, "<script"
        assert_includes html, "before"
        assert_includes html, "after"
      end

      test ".call strips a disallowed inline tag but keeps its text" do
        # The realistic case: an author hand-types an HTML tag in a Markdown
        # field. Pins that a disallowed tag never renders and its text
        # survives -- by whichever layer catches it. This does NOT discriminate
        # unsafe: false from unsafe: true either: <b> is not in ALLOWED_TAGS,
        # so layer 2 (the sanitizer) strips it regardless of what layer 1 did.
        # See ".call does not honour raw HTML even when the tag is on the
        # allowlist" below for the test that actually pins unsafe: false.
        html = BodyRenderer.call("an <b>emphasised</b> word")

        assert_not_includes html, "<b>"
        assert_includes html, "emphasised"
      end

      test ".call drops a raw HTML block entirely" do
        # A line STARTING with raw HTML is a CommonMark HTML block and is
        # dropped whole, including text trailing it on the same line -- which
        # is why the original version of this test, asserting a trailing word
        # survived, was wrong. Pathological input for a Markdown field; the
        # security property is what matters. Like the two tests above, this
        # does not discriminate unsafe: false from unsafe: true (tagfilter
        # neutralises "iframe" either way).
        html = BodyRenderer.call("<iframe src='https://evil.test'></iframe>")

        assert_not_includes html, "<iframe"
      end

      test ".call does not honour raw HTML even when the tag is on the allowlist" do
        # This is the ONE case that discriminates the two layers. `strong` is in
        # ALLOWED_TAGS, so the sanitizer would wave author-typed <strong> straight
        # through -- only commonmarker's unsafe: false stops raw HTML being honoured
        # at all. Flip unsafe: to true and this renders <strong>html</strong>.
        #
        # Tests built on DISALLOWED tags (<b>, <script>, <iframe>) cannot pin this:
        # layer 2 strips those whatever layer 1 does.
        html = BodyRenderer.call("an <strong>html</strong> tag")

        assert_not_includes html, "<strong>"
        assert_includes html, "html"
      end

      test ".call strips a javascript href" do
        assert_not_includes BodyRenderer.call("[x](javascript:alert(1))"), "javascript:"
      end

      test ".call keeps images" do
        html = BodyRenderer.call("![a cover](https://images.test/a.png)")

        assert_includes html, "<img"
        assert_includes html, 'src="https://images.test/a.png"'
        assert_includes html, 'alt="a cover"'
      end

      test ".call returns an html_safe buffer" do
        assert_predicate BodyRenderer.call("hi"), :html_safe?
      end

      test ".call is a pure function of its input" do
        # Rendering is a read-time transform, so calling it twice on the same
        # stored source must give the same answer. This is NOT the same claim as
        # idempotency -- the output is HTML and is never fed back in.
        markdown = "# Title\n\nSome **bold** text and a [link](https://x.test).\n"

        assert_equal BodyRenderer.call(markdown), BodyRenderer.call(markdown)
      end
    end
  end
end
