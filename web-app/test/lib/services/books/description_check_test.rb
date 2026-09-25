require "test_helper"

module Services
  module Books
    class DescriptionCheckTest < ActiveSupport::TestCase
      CLEAN = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

      def setup
        @book = books_books(:war_and_peace)
      end

      test "passes clean text unchanged" do
        result = DescriptionCheck.call(CLEAN)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
        assert_equal [], result.errors
      end

      test "strips markdown citations before checking and keeps the rest" do
        text = "#{CLEAN} ([penguinrandomhouse.com](https://www.penguinrandomhouse.com/x?utm_source=openai))"

        result = DescriptionCheck.call(text)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
      end

      test "strips a citation whose url contains a balanced paren" do
        text = "#{CLEAN} ([en.wikipedia.org](https://en.wikipedia.org/wiki/Foo_(novel)?utm_source=openai))"

        result = DescriptionCheck.call(text)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
      end

      test "stripping is idempotent" do
        text = "#{CLEAN} ([a](https://a.example))"
        once = DescriptionCheck.call(text).data[:text]

        assert_equal once, DescriptionCheck.call(once).data[:text]
      end

      test "flags em dashes, a spaced en dash, and double hyphens" do
        assert_includes DescriptionCheck.call("#{CLEAN} A man — a widow.").errors, "em_dash"
        assert_includes DescriptionCheck.call("#{CLEAN} A man – a widow.").errors, "em_dash"
        assert_includes DescriptionCheck.call("#{CLEAN} A man -- a widow.").errors, "double_hyphen"
      end

      test "an unspaced en dash in a year range is not flagged" do
        result = DescriptionCheck.call("#{CLEAN} The war lasted 1939–1945.")

        refute_includes result.errors, "em_dash"
        assert result.success?
      end

      test "flags a bare url and a markdown link that survived stripping" do
        assert_includes DescriptionCheck.call("#{CLEAN} See https://example.org.").errors, "url"
        assert_includes DescriptionCheck.call("#{CLEAN} See [here](x).").errors, "markdown_link"
      end

      # Title and author naming are the review task's job, not this check's.
      # A string match cannot separate the title "Emma" from the character
      # Emma, and 17k books have one-word titles.
      test "does not flag the title, whatever its length" do
        one_word = ::Books::Book.new(title: "Emma")
        text = "#{CLEAN} Emma Woodhouse meddles in her friends' engagements."

        assert DescriptionCheck.call(text).success?
        assert DescriptionCheck.call("#{CLEAN} It is war and peace in one.").success?
        refute_includes DescriptionCheck.call(text).errors, "names_title"
        assert_equal "Emma", one_word.title
      end

      test "flags fewer than 40 or more than 140 words" do
        assert_includes DescriptionCheck.call("Too short.").errors, "too_short"
        assert_includes DescriptionCheck.call(("word " * 141).strip).errors, "too_long"
      end

      test "counts words separated by non-breaking spaces" do
        text = (["word"] * 48).join("\u00A0")

        refute_includes DescriptionCheck.call(text).errors, "too_short"
      end

      test "flags exactly 39 words as too_short and passes exactly 40" do
        refute_includes DescriptionCheck.call((["word"] * 40).join(" ")).errors, "too_short"
        assert_includes DescriptionCheck.call((["word"] * 39).join(" ")).errors, "too_short"
      end

      test "passes exactly 140 words and flags exactly 141 as too_long" do
        refute_includes DescriptionCheck.call((["word"] * 140).join(" ")).errors, "too_long"
        assert_includes DescriptionCheck.call((["word"] * 141).join(" ")).errors, "too_long"
      end

      test "reports every error at once" do
        result = DescriptionCheck.call("Short — https://x.example")

        assert_equal %w[em_dash url too_short], result.errors
      end
    end
  end
end
