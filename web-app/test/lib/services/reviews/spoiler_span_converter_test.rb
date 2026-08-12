require "test_helper"

module Services
  module Reviews
    class SpoilerSpanConverterTest < ActiveSupport::TestCase
      def convert(html)
        Services::Reviews::SpoilerSpanConverter.call(html)
      end

      test "converts a spoiler span to a marker" do
        assert_equal "He ||dies||.", convert(%(He <span class="review-spoiler">dies</span>.))
      end

      test "converts several spans" do
        assert_equal "||one|| and ||two||",
          convert(%(<span class="review-spoiler">one</span> and <span class="review-spoiler">two</span>))
      end

      test "leaves surrounding markup intact" do
        assert_equal "<p>He ||dies||.</p>", convert(%(<p>He <span class="review-spoiler">dies</span>.</p>))
      end

      test "leaves a body with no spoiler span unchanged" do
        assert_equal "<p>Nothing hidden.</p>", convert("<p>Nothing hidden.</p>")
      end

      test "leaves a span with a different class alone" do
        assert_equal %(<span class="other">x</span>), convert(%(<span class="other">x</span>))
      end

      test "is idempotent" do
        once = convert(%(<span class="review-spoiler">line one<br>line two</span>))

        assert_equal once, convert(once)
      end

      test "returns nil for a nil body" do
        assert_nil convert(nil)
      end

      # Real data: 30 of the 119 stored spans wrap a <br>. Unwrapping in place, not
      # flattening to `.text`, is what keeps it -- `.text` drops elements entirely and
      # <br> contributes no text of its own, so two lines either side would otherwise
      # concatenate into one run-on string with nothing between them.
      test "keeps a <br> inside the span" do
        assert_equal "||line one<br>line two||",
          convert(%(<span class="review-spoiler">line one<br>line two</span>))
      end

      test "keeps an inline tag like <i> inside the span" do
        assert_equal "He ||said <i>hello</i> to her||.",
          convert(%(He <span class="review-spoiler">said <i>hello</i> to her</span>.))
      end

      test "keeps an <a> inside the span" do
        assert_equal %(||click <a href="https://example.com">here</a>||),
          convert(%(<span class="review-spoiler">click <a href="https://example.com">here</a></span>))
      end

      # Real data: review 88697's spoiler span has two <blockquote> children (its span
      # has no <p> ancestor, so HTML5 parsing leaves them nested rather than splitting
      # them out -- see BLOCK_BOUNDARY_TAGS' comment). blockquote is a spoiler SCOPE
      # boundary at render time, so unwrapping would place the opening and closing
      # "||" in two different search scopes that never pair up, leaking everything
      # after the blockquote in the clear. Flattening to `.text` instead loses this
      # span's internal formatting but keeps both markers -- and everything between
      # them -- in one scope.
      test "falls back to flattening when the span contains a block-level child" do
        html = %(<span class="review-spoiler">before<blockquote>quoted</blockquote>after</span>)

        assert_equal "||beforequotedafter||", convert(html)
      end

      test "flattens an empty span to a balanced empty marker pair" do
        assert_equal "||||", convert(%(<span class="review-spoiler"></span>))
      end

      # Documents the precondition stated on the class: converting a span whose own
      # text already contains "||" unbalances the marker pairing. Not exercised by any
      # of the 119 real rows (verified against the full corpus), but pinned here so a
      # future caller with different input guarantees (Task 7) can see the failure
      # mode instead of assuming this handles it safely.
      test "does not balance markers when the span's own text already contains a pipe pair" do
        converted = convert(%(<span class="review-spoiler">a||b</span>))
        assert_equal "||a||b||", converted

        rendered = Services::Reviews::BodySanitizer.render(converted)
        # The non-greedy marker pattern pairs the first three "||"s into one spoiler
        # covering just "a", leaving a bare "||" and "b" exposed in the clear --
        # exactly the leak the precondition warns about.
        assert_equal %(<span class="review-spoiler">a</span>b||), rendered
      end

      # The most valuable check: round-trip a converted body through the render path
      # and confirm the reader sees exactly what they would have seen under the old
      # span-based storage -- one spoiler span whose revealed text matches the
      # original span's text exactly, for shapes beyond the brief's bare-text case.
      [
        ["plain text", %(He <span class="review-spoiler">dies</span>.)],
        ["a <br>", %(<span class="review-spoiler">line one<br>line two</span>)],
        ["an inline tag", %(He <span class="review-spoiler">said <i>hello</i> to her</span>.)]
      ].each do |(label, original)|
        test "round-trips through render with #{label} unchanged" do
          rendered = Services::Reviews::BodySanitizer.render(convert(original))

          original_span = Nokogiri::HTML5.fragment(original).css("span.review-spoiler").first
          rendered_span = Nokogiri::HTML5.fragment(rendered).css("span.review-spoiler").first

          assert rendered_span, "expected a span.review-spoiler in the rendered output"
          assert_equal original_span.text, rendered_span.text
        end
      end
    end
  end
end
