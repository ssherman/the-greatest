require "test_helper"

module Services
  module Reviews
    class BodySanitizerTest < ActiveSupport::TestCase
      test ".call returns nil for nil" do
        assert_nil BodySanitizer.call(nil)
      end

      test ".call returns nil for an empty string" do
        assert_nil BodySanitizer.call("")
      end

      test ".call returns nil for a whitespace-only body" do
        assert_nil BodySanitizer.call("   \n\t  ")
      end

      test ".call keeps allowed formatting tags" do
        body = "<p>A <i>great</i> <b>book</b>, <strong>truly</strong>.</p><blockquote>Quoted.</blockquote>"
        assert_equal body, BodySanitizer.call(body)
      end

      test ".call normalizes br tags and keeps them" do
        assert_equal "one<br>two", BodySanitizer.call("one<br/>two")
      end

      test ".call strips script tags" do
        result = BodySanitizer.call("safe <script>alert('xss')</script>")
        assert_not_includes result, "<script"
      end

      test ".call strips iframe, style and input tags" do
        result = BodySanitizer.call(
          "<iframe src='https://evil.test'></iframe><style>body{}</style><input value='x'>text"
        )
        assert_not_includes result, "<iframe"
        assert_not_includes result, "<style"
        assert_not_includes result, "<input"
        assert_includes result, "text"
      end

      test ".call returns nil when the body is only an image" do
        assert_nil BodySanitizer.call(%(<img src="https://example.test/cover.png">))
      end

      test ".call scrubs a javascript href but keeps a real link" do
        result = BodySanitizer.call(
          %(<a href="javascript:alert(1)">bad</a> <a href="https://example.test" title="t">good</a>)
        )
        assert_not_includes result, "javascript:"
        assert_includes result, %(<a href="https://example.test" title="t">good</a>)
      end

      test ".call strips a user-supplied span and its class" do
        result = BodySanitizer.call(%(<span class="review-spoiler">not really a spoiler</span>))
        assert_not_includes result, "<span"
        assert_includes result, "not really a spoiler"
      end

      test ".call converts a spoiler tag to a safe span" do
        assert_equal %(before <span class="review-spoiler">the butler did it</span> after),
          BodySanitizer.call("before <spoiler>the butler did it</spoiler> after")
      end

      test ".call converts multiple spoiler tags" do
        assert_equal %(<span class="review-spoiler">one</span> and <span class="review-spoiler">two</span>),
          BodySanitizer.call("<spoiler>one</spoiler> and <spoiler>two</spoiler>")
      end

      test ".call ignores attributes on a spoiler tag" do
        assert_equal %(<span class="review-spoiler">y</span>),
          BodySanitizer.call(%(<spoiler onclick="bad()">y</spoiler>))
      end

      test ".call leaves an unclosed spoiler tag as plain text" do
        result = BodySanitizer.call("<spoiler>never closed")
        assert_not_includes result, "<span"
        assert_includes result, "never closed"
      end

      test ".call cannot have its token forged from user text" do
        body = "spo1234567890abcdef hello spc1234567890abcdef"
        assert_not_includes BodySanitizer.call(body), "<span"
      end

      test ".call does not truncate long bodies" do
        body = "a" * 30_000
        assert_equal 30_000, BodySanitizer.call(body).length
      end
    end
  end
end
