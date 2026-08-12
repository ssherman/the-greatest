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

      # Regression: pre was missing from BLOCK_MARKUP, so paragraphize blank-line-split
      # the raw string right through a <pre> block's own boundaries -- "<pre>line
      # one\n\nline two</pre>" became "<p><pre>line one</p><p>line two</pre></p>", a
      # <pre> opened in one paragraph and closed in another. pre is not in
      # ALLOWED_TAGS, so the sanitizer always unwraps it (keeps the text, drops the
      # tag) -- the guard's job is only to stop paragraphize reinterpreting the blank
      # line inside it before that unwrapping ever happens.
      test ".call does not splice paragraph tags across a pre tag's boundary" do
        result = BodySanitizer.call("<pre>line one\n\nline two</pre>")

        assert_equal "line one\n\nline two", result
        refute_includes result, "<p"
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

      # Regression: for_editing only reversed spoiler spans, not paragraphize's <p>
      # tags, so reopening the dialog on a multi-paragraph review showed the literal
      # <p> markup instead of the blank lines the author typed.
      test "for_editing reverses call's paragraph conversion back to a blank line" do
        stored = Services::Reviews::BodySanitizer.call("Line one.\n\nLine two.")

        assert_equal "Line one.\n\nLine two.", Services::Reviews::BodySanitizer.for_editing(stored)
      end

      test "for_editing reverses call's single-newline conversion back to a line break" do
        stored = Services::Reviews::BodySanitizer.call("Line one.\nLine two.")

        assert_equal "Line one.\nLine two.", Services::Reviews::BodySanitizer.for_editing(stored)
      end

      # The property the fix is for: a plain-text body must survive an arbitrary
      # number of edit cycles unchanged, not just one round trip. Checked twice, not
      # once, so a fix that merely reverses call's output without also being a stable
      # fixed point (e.g. one that drifts a <br> into something paragraphize itself
      # would not have written) cannot pass by accident.
      test "a plain-text body with mixed single and blank lines survives repeated edit cycles unchanged" do
        raw = "Para one line A.\nPara one line B.\n\nPara two."

        stored = Services::Reviews::BodySanitizer.call(raw)
        edited = Services::Reviews::BodySanitizer.for_editing(stored)
        assert_equal raw, edited

        restored = Services::Reviews::BodySanitizer.call(edited)
        assert_equal stored, restored

        edited_again = Services::Reviews::BodySanitizer.for_editing(restored)
        restored_again = Services::Reviews::BodySanitizer.call(edited_again)
        assert_equal stored, restored_again
      end

      # Companion safety check for the guard test above ("does not paragraphize a body
      # that already contains a p tag"): that body's own internal "\n" (not a real
      # <br>) must not be reinterpreted as a paragraph break on the way back out
      # either, or an author who reopens a migrated review and saves without changing
      # anything would silently rewrite it -- BodySanitizer.for_editing must not
      # mistake pass-through markup for markup it generated itself. This is exactly
      # why for_editing verifies its candidate against .call rather than reversing
      # any body shaped like a sequence of <p> tags: reversing this one would produce
      # "First.\n\nSecond.\nStill second.", and re-running .call on that text (no
      # BLOCK_MARKUP left to guard it) would turn the "\n" into a real <br>, changing
      # the stored body on a no-op edit.
      test "for_editing does not mangle a migrated body whose own p tag was never paragraphize's" do
        body = "<p>First.</p><p>Second.\nStill second.</p>"
        stored = Services::Reviews::BodySanitizer.call(body)

        assert_equal body, stored # pins the existing guard behaviour this test relies on
        assert_equal body, Services::Reviews::BodySanitizer.for_editing(stored)
      end

      # Same guard, the other pinned shape: real markup with a bare <br> and bare text
      # at the top level, which paragraphize itself never produces.
      test "for_editing does not mangle a migrated body with its own br tag" do
        body = "First line.<br>Second line.\n\nThird paragraph, never wrapped."
        stored = Services::Reviews::BodySanitizer.call(body)

        assert_equal body, stored
        assert_equal body, Services::Reviews::BodySanitizer.for_editing(stored)
      end

      # Composition: a paragraph break and a spoiler in the same body. Proves
      # restore_paragraphs' per-paragraph serialization puts the restored <spoiler>
      # tag (not the stored <span>) back into the reversed text.
      test "for_editing reverses paragraph conversion and a spoiler together" do
        raw = "Before the twist.\n\n<spoiler>Snape kills Dumbledore</spoiler>"
        stored = Services::Reviews::BodySanitizer.call(raw)

        assert_equal raw, Services::Reviews::BodySanitizer.for_editing(stored)
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

      test "render converts a spoiler marker into a spoiler span" do
        html = Services::Reviews::BodySanitizer.render("He ||dies|| at the end.")

        assert_includes html, %(<span class="review-spoiler">dies</span>)
        assert_includes html, "at the end."
      end

      test "render converts a spoiler marker in a body with no tags at all" do
        html = Services::Reviews::BodySanitizer.render("||everything||")

        assert_includes html, %(<span class="review-spoiler">everything</span>)
      end

      test "render converts several spoiler markers in one body" do
        html = Services::Reviews::BodySanitizer.render("||one|| and ||two||")

        assert_equal 2, html.scan("review-spoiler").length
      end

      test "render leaves an unpaired marker alone" do
        html = Services::Reviews::BodySanitizer.render("a || b")

        refute_includes html, "review-spoiler"
        assert_includes html, "a || b"
      end

      # A <script> tag here would pass even without any spoiler-aware escaping at
      # all -- RENDER_TAGS already strips it upstream, before convert_spoiler_markers
      # ever sees a text node. Special characters that legitimately survive the
      # sanitizer as plain text (a literal & or <) next to a marker are the real
      # test: the text this method relocates into a new node must still serialize
      # correctly, not leak a bare & or < that could be misread as markup.
      test "render safely serializes text around a spoiler marker" do
        html = Services::Reviews::BodySanitizer.render("Fish & chips <3 ||hidden||")

        assert_includes html, "Fish &amp; chips &lt;3 "
        assert_includes html, %(<span class="review-spoiler">hidden</span>)
        parsed = Nokogiri::HTML5.fragment(html)
        assert_equal "Fish & chips <3 hidden", parsed.text
      end

      # Same reasoning as above, aimed at the captured content instead: a <script>
      # tag inside the marker would also pass with no spoiler-aware escaping at
      # all, since the sanitizer already removes it before conversion runs.
      # Characters that survive as literal text within the marker are what this
      # method is actually responsible for re-serializing safely.
      test "render escapes markup inside a spoiler marker" do
        html = Services::Reviews::BodySanitizer.render("||1 < 2 & 3||")

        assert_includes html, %(<span class="review-spoiler">1 &lt; 2 &amp; 3</span>)
        span = Nokogiri::HTML5.fragment(html).at_css("span.review-spoiler")
        assert_equal "1 < 2 & 3", span.text
      end

      test "render escapes a script tag inside a spoiler marker" do
        html = Services::Reviews::BodySanitizer.render("||<script>alert(1)</script>||")

        refute_includes html, "<script"
        assert_includes html, "review-spoiler"
      end

      # The whole safety property: an attribute value is not a text node. A
      # negative check alone (refute_includes the spliced string) would also pass
      # if the href were simply dropped, so this asserts the href survives INTACT.
      test "render does not splice a span into an attribute value" do
        html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.test/||evil||">click</a>))

        anchor = Nokogiri::HTML5.fragment(html).at_css("a")
        assert_equal "https://example.test/||evil||", anchor["href"]
        assert_equal "click", anchor.text
        refute_includes html, %(href="https://example.test/<span)
      end

      test "render wraps blank-line-separated text in paragraphs" do
        html = Services::Reviews::BodySanitizer.render("Line one.\n\nLine two.")

        assert_includes html, "<p>Line one.</p>"
        assert_includes html, "<p>Line two.</p>"
      end

      test "render turns a single newline into a line break" do
        html = Services::Reviews::BodySanitizer.render("Line one.\nStill one.")

        assert_includes html, "<br>"
      end

      test "render leaves a body that already has block markup alone" do
        html = Services::Reviews::BodySanitizer.render("<p>Migrated.</p><p>Body.</p>")

        assert_equal 2, html.scan("<p>").length
      end

      test "render converts a spoiler marker inside a paragraph" do
        html = Services::Reviews::BodySanitizer.render("Intro.\n\nHe ||dies||.")

        assert_includes html, "<p>Intro.</p>"
        assert_includes html, %(<span class="review-spoiler">dies</span>)
      end

      test "render still hardens links" do
        html = Services::Reviews::BodySanitizer.render(%(<a href="https://example.test">x</a>))

        assert_includes html, %(rel="nofollow ugc noopener")
        assert_includes html, %(target="_blank")
      end

      # paragraphize runs before convert_spoiler_markers and turns a single typed
      # newline into a real <br> element, splitting what was one text node into two.
      # A spoiler must still work across that split -- matching has to reach across
      # node boundaries, not just within a single text node.
      test "render converts a spoiler marker across a single newline" do
        html = Services::Reviews::BodySanitizer.render("||He dies\nand so does she||")

        assert_includes html, %(<span class="review-spoiler">He dies<br>and so does she</span>)
      end

      # The marker delimiters sit outside the <b>, so the whole element has to be
      # picked up and moved into the span as a real, still-functioning tag -- not
      # escaped the way disallowed markup typed inside a marker is.
      test "render converts a spoiler marker around an inline tag" do
        html = Services::Reviews::BodySanitizer.render("||He <b>dies</b> at the end||")

        assert_includes html, %(<span class="review-spoiler">He <b>dies</b> at the end</span>)
      end

      # Documented scope limit, not a bug: a spoiler spanning a blank line (a
      # paragraph boundary) is not supported, matching Discord's own behavior.
      # Each marker here is alone in its own <p> once paragraphize runs, so
      # neither pairs up and both are left exactly as typed.
      test "render does not convert a spoiler marker pair that spans a paragraph break" do
        html = Services::Reviews::BodySanitizer.render("Para one ||starts.\n\nEnds|| here.")

        refute_includes html, "review-spoiler"
        assert_includes html, "||starts."
        assert_includes html, "Ends||"
      end

      # Regression (Critical 1): the OPENING "||" itself straddled a node boundary
      # once paragraphize turned the newline between its two pipes into a <br>,
      # so the captured content's own start landed in a different node than the
      # outer delimiter's start. Slicing against the wrong node's offset returned
      # nil and crashed on `.empty?` -- a 500 on a public page from ordinary
      # typing, no HTML required. Must render successfully and lose nothing.
      test "render does not raise when an opening spoiler marker straddles a newline" do
        html = Services::Reviews::BodySanitizer.render("Rated 9|\n|10, and ||the twist|| is great")

        assert_equal "<p>Rated 9|<br>|10, and ||the twist|| is great</p>", html
      end

      # Regression (Critical 2): the CLOSING "||" straddled a node boundary the
      # same way, but on this side the wrong offset was negative, so Ruby quietly
      # returned a wrong-but-non-nil slice instead of raising -- duplicating and
      # losing text rather than crashing. Must render successfully with every
      # character preserved exactly once.
      test "render does not lose or duplicate text when a closing spoiler marker straddles a newline" do
        html = Services::Reviews::BodySanitizer.render("a ||b|\n|c and more")

        assert_equal "<p>a ||b|<br>|c and more</p>", html
      end

      # Important 3: the write allowlist keeps b/i/em/strong/a, so a marker pair can
      # be typed with one delimiter inside an inline tag and the other outside it.
      # The parent guard keeps this structurally safe (nothing corrupts), but it is
      # a real, reachable shape via ordinary typing -- not a hypothetical -- and it
      # fails OPEN: the spoiler is left exactly as typed, visible "||" and all,
      # rather than hidden. Documented as a known, accepted limit, not silently.
      test "render does not convert a spoiler marker pair split across an inline tag boundary" do
        html = Services::Reviews::BodySanitizer.render("<b>||He dies</b> at the end||")

        assert_equal "<b>||He dies</b> at the end||", html
        refute_includes html, "review-spoiler"
      end

      test "render does not convert a spoiler marker pair split across an inline tag boundary the other way" do
        html = Services::Reviews::BodySanitizer.render("He was ||shocked when <b>she died||</b>")

        assert_equal "He was ||shocked when <b>she died||</b>", html
        refute_includes html, "review-spoiler"
      end

      # Minor 4 (SPOILER_SCOPE_BOUNDARY_TAGS comment fix): a <p> nested inside an
      # inline tag is reachable through convert_spoiler_run's descendant walk even
      # though <p> is a scope boundary at the sibling level. Pinning the actual
      # (safe, non-crashing) behavior: the whole subtree, <p> included, moves into
      # the spoiler span. No injection risk either way -- span/class are the only
      # things this method ever writes -- this just documents what happens rather
      # than leaving it unspecified.
      test "render moves a paragraph nested inside an inline tag into the spoiler span" do
        html = Services::Reviews::BodySanitizer.render("<b>||a<p>mid</p>b||</b>")

        assert_equal %(<b><span class="review-spoiler">a<p>mid</p>b</span></b>), html
      end

      # Corpus shape (id=124730): plain text ending in a single trailing newline,
      # no block markup at all. Before this task, render's newline was inert (no
      # <br>/<p> rule to fall back on) and the body rendered as one run-on line;
      # this pins the now-deliberate paragraph conversion for that shape.
      test "render turns a single line of plain text with a trailing newline into one paragraph" do
        html = Services::Reviews::BodySanitizer.render("average\n")

        assert_equal "<p>average</p>", html
      end

      # Corpus shape (id=130717): a quoted line, a single newline, then the rest of
      # the review -- no blank line, so this is one paragraph with a line break,
      # not two paragraphs.
      test "render turns a quoted line and a newline into one paragraph with a line break" do
        html = Services::Reviews::BodySanitizer.render(%("Great book."\nReally enjoyed it.))

        assert_equal %(<p>"Great book."<br>Really enjoyed it.</p>), html
      end

      # Regression: the round-2 guard checked node-index EQUALITY, which is
      # stricter than the slicing actually needs -- a marker sitting flush
      # against a tag with no text in between (nothing between "||" and "<b>",
      # or between "</b>" and "||") legitimately lands the captured bounds
      # exactly ON a node boundary, and got bailed on even though nothing was
      # unsafe about converting it. 119 of a 15,817-input fuzz regressed this
      # way. The property test below checks safety invariants (no crash, no
      # corruption) but would not by itself catch UNDER-conversion -- these
      # five, the reviewer's own named examples, pin the specific fix.
      test "render converts a spoiler marker flush against an inline tag with no text between" do
        assert_equal(
          %(The killer is <span class="review-spoiler"><b>the butler</b></span>),
          Services::Reviews::BodySanitizer.render("The killer is ||<b>the butler</b>||")
        )
        assert_equal(
          %(<span class="review-spoiler">He <b>dies</b></span>),
          Services::Reviews::BodySanitizer.render("||He <b>dies</b>||")
        )
        assert_equal(
          %(<span class="review-spoiler"><b>x</b></span> tail),
          Services::Reviews::BodySanitizer.render("||<b>x</b>|| tail")
        )
      end

      test "render converts a spoiler marker flush against a newline-turned-br with no text between" do
        assert_equal(
          %(<p><span class="review-spoiler"><br>he dies</span></p>),
          Services::Reviews::BodySanitizer.render("||\nhe dies||")
        )
        assert_equal(
          %(<p><span class="review-spoiler">he dies<br></span></p>),
          Services::Reviews::BodySanitizer.render("||he dies\n||")
        )
      end

      # Permanent regression net. Three separate code review rounds each found a
      # defect in spoiler-marker matching (a crash, a text-corrupting negative
      # slice, an over-rejection that silently un-hid valid spoilers) that every
      # example-based test above missed, because each one needed a SPECIFIC
      # arrangement of "|", a newline, and a tag boundary that no hand-picked
      # example happened to hit. This asserts the underlying safety invariants
      # across every such arrangement up to a fixed length, instead of trusting
      # another hand-picked example to happen to cover the next one.
      #
      # Exhaustive over a small, FIXED alphabet, not random -- so a failure is
      # always reproducible from the corpus alone, and CI can never flake on it.
      # Every token is chosen to matter: "a" is inert filler; "|" is the marker
      # character itself; "\n" is what paragraphize turns into a <br> element,
      # splitting a text node; "<b>"/"</b>" is a real element that can split a
      # marker pair across siblings the same way. All three past defects involved
      # exactly two or three of these landing next to each other, so length 6
      # covers every such adjacency with room either side.
      test "render satisfies its safety invariants across an exhaustive small corpus" do
        tokens = ["a", "|", "\n", "<b>", "</b>"]
        corpus = tokens.repeated_permutation(6).map(&:join)

        corpus.each do |input|
          # Any exception here fails the test immediately -- this is the
          # "rendering never raises" invariant; no explicit assertion needed.
          html = Services::Reviews::BodySanitizer.render(input)
          next if html.nil?

          fragment = Nokogiri::HTML5.fragment(html)
          rendered_text = fragment.text
          span_count = html.scan(%(class="review-spoiler")).length

          # No letter is ever added or removed, spoiler conversion or not.
          assert_equal input.count("a"), rendered_text.count("a"),
            "letter count changed for #{input.inspect} -- rendered #{html.inspect}"

          # Every converted span removes exactly the two marker pairs (4 pipe
          # characters) that produced it; any "|" left unconverted -- paired or
          # not -- must remain fully in the visible text. This is what catches
          # both text loss (fewer pipes than predicted) and duplication (more).
          assert_equal input.count("|") - (4 * span_count), rendered_text.count("|"),
            "pipe count did not shrink by exactly 4 per span for #{input.inspect} -- rendered #{html.inspect}"

          # The only structural change spoiler conversion is allowed to make is
          # adding spans. Comparing against the SAME input with every "|"
          # replaced by "a" (never deleted -- deleting would itself shift where
          # paragraphize splits blocks, a false signal, not a real one) isolates
          # exactly that change: replacing keeps every newline and tag in the
          # same position, guarantees zero possible spoiler matches, and so
          # renders the paragraph/tag structure spoiler conversion must not
          # otherwise disturb.
          baseline_html = Services::Reviews::BodySanitizer.render(input.tr("|", "a"))
          baseline_tally = element_tally(baseline_html)
          actual_tally = element_tally(html)
          expected_tally = baseline_tally.dup
          expected_tally["span"] = expected_tally.fetch("span", 0) + span_count if span_count > 0
          assert_equal expected_tally, actual_tally,
            "element tally drifted beyond the spans produced for #{input.inspect} -- rendered #{html.inspect}"

          fragment.css("span").each do |span|
            assert_equal ["class"], span.attributes.keys,
              "spoiler span gained an unexpected attribute for #{input.inspect} -- rendered #{html.inspect}"
            assert_equal Services::Reviews::BodySanitizer::SPOILER_CLASS, span["class"],
              "spoiler span class drifted for #{input.inspect} -- rendered #{html.inspect}"
          end

          fragment.css("b, p, br").each do |node|
            assert_empty node.attributes.keys,
              "#{node.name} gained an unexpected attribute for #{input.inspect} -- rendered #{html.inspect}"
          end
        end
      end

      private

      def element_tally(html)
        return Hash.new(0) if html.nil?

        Nokogiri::HTML5.fragment(html).css("*").each_with_object(Hash.new(0)) { |node, tally| tally[node.name] += 1 }
      end
    end
  end
end
