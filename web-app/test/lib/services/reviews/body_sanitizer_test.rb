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

      test ".call returns nil for a body that is only a br tag" do
        assert_nil BodySanitizer.call("<br>")
      end

      test ".call returns nil for a body that is only br tags" do
        assert_nil BodySanitizer.call("<br><br>")
      end

      test ".call returns nil for a body that is only an empty paragraph" do
        assert_nil BodySanitizer.call("<p></p>")
      end

      test ".call returns nil for a body that is only whitespace inside a blockquote" do
        assert_nil BodySanitizer.call("<blockquote>  </blockquote>")
      end

      test ".call returns nil for a link with no text" do
        assert_nil BodySanitizer.call(%(<a href="https://x.test"></a>))
      end

      test ".call returns nil for a body that is only a non-breaking space" do
        assert_nil BodySanitizer.call("<p>&nbsp;</p>")
      end

      # String#strip removes only ASCII whitespace, so each of these would otherwise
      # persist as a visually blank review that `with_body` counts.
      test ".call returns nil for a body of any Unicode whitespace" do
        {
          "em space (U+2003)" => "<p>&emsp;</p>",
          "en space (U+2002)" => "<p>&ensp;</p>",
          "thin space (U+2009)" => "<p>&thinsp;</p>",
          "ideographic space (U+3000)" => "<p>　</p>",
          "mixed" => "<p>  　</p>"
        }.each do |label, body|
          assert_nil BodySanitizer.call(body), "expected nil for #{label}"
        end
      end

      test ".call returns nil for a body of only zero-width characters" do
        {
          "zero-width space (U+200B)" => "<p>&#8203;</p>",
          "zero-width joiner (U+200D)" => "<p>‍</p>",
          "byte order mark (U+FEFF)" => "<p>﻿</p>"
        }.each do |label, body|
          assert_nil BodySanitizer.call(body), "expected nil for #{label}"
        end
      end

      test ".call keeps a body whose text is padded with Unicode whitespace" do
        result = BodySanitizer.call("<p>&nbsp;Great&emsp;book&nbsp;</p>")

        assert_not_nil result
        text = Nokogiri::HTML5.fragment(result).text
        assert_includes text, "Great"
        assert_includes text, "book"
      end

      test ".call keeps a single visible character" do
        assert_equal "<p>x</p>", BodySanitizer.call("<p>x</p>")
      end

      test ".call keeps a br tag between real text" do
        assert_equal "one<br>two", BodySanitizer.call("one<br>two")
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

      test ".call closes an unclosed spoiler tag" do
        assert_equal %(<span class="review-spoiler">never closed</span>),
          BodySanitizer.call("<spoiler>never closed")
      end

      test ".call converts nested spoiler tags" do
        assert_equal %(<span class="review-spoiler">a<span class="review-spoiler">b</span>c</span>),
          BodySanitizer.call("<spoiler>a<spoiler>b</spoiler>c</spoiler>")
      end

      test ".call replaces a class supplied on a spoiler tag" do
        assert_equal %(<span class="review-spoiler">x</span>),
          BodySanitizer.call(%(<spoiler class="evil">x</spoiler>))
      end

      test ".call strips every attribute on a spoiler tag, not just class" do
        assert_equal %(<span class="review-spoiler">x</span>),
          BodySanitizer.call(%(<spoiler title="secret">x</spoiler>))
      end

      # Regression: a string-tokenizing implementation spliced raw markup into the
      # quoted attribute value here, producing malformed HTML.
      test ".call does not splice markup into an href attribute value" do
        result = BodySanitizer.call(%(<a href="<spoiler>evil</spoiler>">click</a>))
        assert_not_includes result, "<span"

        anchor = Nokogiri::HTML5.fragment(result).at_css("a")
        assert_equal "<spoiler>evil</spoiler>", anchor["href"]
        assert_equal "click", anchor.text
        assert_equal ["href"], anchor.attributes.keys
      end

      test ".call does not splice markup into a title attribute value" do
        result = BodySanitizer.call(%(<a title="<spoiler>y</spoiler>">link</a>))
        assert_not_includes result, "<span"

        anchor = Nokogiri::HTML5.fragment(result).at_css("a")
        assert_equal "<spoiler>y</spoiler>", anchor["title"]
        assert_equal "link", anchor.text
      end

      test ".call strips an event handler smuggled past a spoiler tag" do
        result = BodySanitizer.call(
          %(<a title="<spoiler>x" onmouseover="alert(1)" y="</spoiler>">link</a>)
        )
        assert_not_includes result, "onmouseover"
        assert_not_includes result, "alert(1)"
      end

      test ".call does not truncate long bodies" do
        body = "a" * 30_000
        assert_equal 30_000, BodySanitizer.call(body).length
      end
    end
  end
end
