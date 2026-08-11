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

      # Proven end to end in production: a stored body of "Line one.\n\nLine two."
      # rendered as exactly that, one continuous line, because nothing converted the
      # newlines into markup and .review-body has no white-space CSS rule to fall
      # back on.
      test ".call turns a blank-line-separated plain-text body into paragraphs" do
        assert_equal "<p>Line one.</p><p>Line two.</p>",
          BodySanitizer.call("Line one.\n\nLine two.")
      end

      test ".call turns a single newline in a plain-text body into a line break" do
        assert_equal "<p>Line one.<br>Line two.</p>",
          BodySanitizer.call("Line one.\nLine two.")
      end

      test ".call ignores extra blank lines around and between paragraphs" do
        assert_equal "<p>Line one.</p><p>Line two.</p>",
          BodySanitizer.call("\n\nLine one.\n\n\n\nLine two.\n\n")
      end

      # Guard: a body that already has real paragraph structure -- every migrated row
      # does -- must pass through untouched, not have its own internal newlines
      # reinterpreted as line breaks.
      test ".call does not paragraphize a body that already contains a p tag" do
        body = "<p>First.</p><p>Second.\nStill second.</p>"
        assert_equal body, BodySanitizer.call(body)
      end

      test ".call does not paragraphize a body that already contains a br tag" do
        body = "First line.<br>Second line.\n\nThird paragraph, never wrapped."
        assert_equal body, BodySanitizer.call(body)
      end

      test "render keeps the spoiler span the write path produced" do
        stored = Services::Reviews::BodySanitizer.call("<p>He <spoiler>dies</spoiler>.</p>")

        html = Services::Reviews::BodySanitizer.render(stored)

        assert_includes html, %(<span class="review-spoiler">dies</span>)
      end

      # Companion to "render keeps the spoiler span the write path produced" above --
      # pins what would happen to that same stored body if .call were used instead.
      test "re-running call on a stored body would destroy the spoiler -- do not do it" do
        stored = Services::Reviews::BodySanitizer.call("<p>He <spoiler>dies</spoiler>.</p>")

        round_tripped = Services::Reviews::BodySanitizer.call(stored)

        refute_includes round_tripped, "review-spoiler"
        assert_includes round_tripped, "dies"
      end

      test "render strips a script even though the write path should have already" do
        html = Services::Reviews::BodySanitizer.render("<p>Hi</p><script>alert(1)</script>")

        refute_includes html, "script"
        assert_includes html, "Hi"
      end

      test "render strips an event handler smuggled onto an allowed tag" do
        html = Services::Reviews::BodySanitizer.render(%(<p onclick="alert(1)">Hi</p>))

        refute_includes html, "onclick"
      end

      test "render marks untrusted links nofollow, ugc, noopener and opens them away from the page" do
        html = Services::Reviews::BodySanitizer.render(%(<p><a href="https://example.com">link</a></p>))

        assert_includes html, %(rel="nofollow ugc noopener")
        assert_includes html, %(target="_blank")
      end

      test "render replaces any rel the body already carried" do
        html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.com" rel="dofollow">link</a>))

        refute_includes html, "dofollow"
        assert_includes html, %(rel="nofollow ugc noopener")
      end

      test "render returns an html_safe buffer" do
        html = Services::Reviews::BodySanitizer.render("<p>Hi</p>")

        assert_predicate html, :html_safe?
      end

      test "render returns nil for a nil or blank body" do
        assert_nil Services::Reviews::BodySanitizer.render(nil)
        assert_nil Services::Reviews::BodySanitizer.render("")
        assert_nil Services::Reviews::BodySanitizer.render("   ")
      end

      test "render strips a javascript href" do
        html = Services::Reviews::BodySanitizer.render(%(<a href="javascript:alert(1)">bad</a>))

        refute_includes html, "javascript:"
      end

      test "render strips a non-spoiler class entirely" do
        html = Services::Reviews::BodySanitizer.render(%(<p class="fixed inset-0 z-50">x</p>))

        refute_includes html, "fixed"
        refute_includes html, "class"
      end

      test "render narrows a spoiler span's class to exactly review-spoiler" do
        html = Services::Reviews::BodySanitizer.render(
          %(<span class="review-spoiler fixed inset-0">dies</span>)
        )

        assert_includes html, %(<span class="review-spoiler">dies</span>)
        refute_includes html, "fixed"
        refute_includes html, "inset-0"
      end

      test "for_editing returns nil for a nil body" do
        assert_nil Services::Reviews::BodySanitizer.for_editing(nil)
      end

      test "for_editing converts a stored spoiler span back to a spoiler tag" do
        stored = Services::Reviews::BodySanitizer.call("<p>He <spoiler>dies</spoiler>.</p>")

        assert_equal "<p>He <spoiler>dies</spoiler>.</p>", Services::Reviews::BodySanitizer.for_editing(stored)
      end

      test "for_editing converts several stored spoiler spans back to spoiler tags" do
        stored = Services::Reviews::BodySanitizer.call("<spoiler>one</spoiler> and <spoiler>two</spoiler>")

        assert_equal "<spoiler>one</spoiler> and <spoiler>two</spoiler>",
          Services::Reviews::BodySanitizer.for_editing(stored)
      end

      test "for_editing returns a stored body with no spoilers unchanged" do
        stored = Services::Reviews::BodySanitizer.call("<p>No spoilers here.</p>")

        assert_equal "<p>No spoilers here.</p>", Services::Reviews::BodySanitizer.for_editing(stored)
      end

      # The exact scenario the bug report proved: a reader hides a spoiler, later
      # reopens the dialog, and saves again without touching the spoiler text. Without
      # for_editing restoring <spoiler>, the textarea would show the raw <span> markup
      # and the next .call would strip it, publishing the spoiler in the clear.
      test "for_editing round-trips through call without destroying the spoiler" do
        stored = Services::Reviews::BodySanitizer.call("<spoiler>Snape kills Dumbledore</spoiler>")
        edited = Services::Reviews::BodySanitizer.for_editing(stored)
        resaved = Services::Reviews::BodySanitizer.call(edited)

        assert_equal stored, resaved
        assert_includes resaved, "review-spoiler"
      end

      test "render strips a title attribute, including from a spoiler span" do
        html = Services::Reviews::BodySanitizer.render(
          %(<a href="https://example.com" title="secret">link</a>)
        )
        refute_includes html, "title"
        refute_includes html, "secret"

        spoiler_html = Services::Reviews::BodySanitizer.render(
          %(<span class="review-spoiler" title="the butler did it">dies</span>)
        )
        refute_includes spoiler_html, "title"
        refute_includes spoiler_html, "the butler did it"
        assert_includes spoiler_html, %(<span class="review-spoiler">dies</span>)
      end
    end
  end
end
