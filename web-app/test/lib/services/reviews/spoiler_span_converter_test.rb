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
        result = convert(%(<p>He <span class="review-spoiler">dies</span>.</p>))

        assert_includes result, "<p>"
        assert_includes result, "||dies||"
      end

      test "leaves a body with no spoiler span unchanged" do
        assert_equal "<p>Nothing hidden.</p>", convert("<p>Nothing hidden.</p>")
      end

      test "leaves a span with a different class alone" do
        assert_equal %(<span class="other">x</span>), convert(%(<span class="other">x</span>))
      end

      test "is idempotent" do
        once = convert(%(He <span class="review-spoiler">dies</span>.))

        assert_equal once, convert(once)
      end

      test "returns nil for a nil body" do
        assert_nil convert(nil)
      end
    end
  end
end
