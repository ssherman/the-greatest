require "test_helper"

module Services
  module Books
    class DescriptionCheckTest < ActiveSupport::TestCase
      CLEAN = ("In a small Connecticut town, a young man takes a job caring for an elderly widow. " * 3).strip

      def setup
        @book = books_books(:war_and_peace)
      end

      test "passes clean text unchanged" do
        result = DescriptionCheck.call(CLEAN, book: @book)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
        assert_equal [], result.errors
      end

      test "strips markdown citations before checking and keeps the rest" do
        text = "#{CLEAN} ([penguinrandomhouse.com](https://www.penguinrandomhouse.com/x?utm_source=openai))"

        result = DescriptionCheck.call(text, book: @book)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
      end

      test "strips a citation whose url contains a balanced paren" do
        text = "#{CLEAN} ([en.wikipedia.org](https://en.wikipedia.org/wiki/Foo_(novel)?utm_source=openai))"

        result = DescriptionCheck.call(text, book: @book)

        assert result.success?
        assert_equal CLEAN, result.data[:text]
      end

      test "stripping is idempotent" do
        text = "#{CLEAN} ([a](https://a.example))"
        once = DescriptionCheck.call(text, book: @book).data[:text]

        assert_equal once, DescriptionCheck.call(once, book: @book).data[:text]
      end

      test "flags em dashes, a spaced en dash, and double hyphens" do
        assert_includes DescriptionCheck.call("#{CLEAN} A man — a widow.", book: @book).errors, "em_dash"
        assert_includes DescriptionCheck.call("#{CLEAN} A man – a widow.", book: @book).errors, "em_dash"
        assert_includes DescriptionCheck.call("#{CLEAN} A man -- a widow.", book: @book).errors, "double_hyphen"
      end

      test "an unspaced en dash in a year range is not flagged" do
        result = DescriptionCheck.call("#{CLEAN} The war lasted 1939–1945.", book: @book)

        refute_includes result.errors, "em_dash"
        assert result.success?
      end

      test "flags a bare url and a markdown link that survived stripping" do
        assert_includes DescriptionCheck.call("#{CLEAN} See https://example.org.", book: @book).errors, "url"
        assert_includes DescriptionCheck.call("#{CLEAN} See [here](x).", book: @book).errors, "markdown_link"
      end

      test "flags the book's title as a whole phrase, case-insensitively" do
        result = DescriptionCheck.call("#{CLEAN} It is war AND peace in one.", book: @book)

        assert_includes result.errors, "names_title"
      end

      test "does not flag the title inside another word" do
        book = ::Books::Book.new(title: "It")
        text = "#{CLEAN} Her wit made the item a hit."

        assert DescriptionCheck.call(text, book: book).success?
      end

      test "flags fewer than 40 or more than 140 words" do
        assert_includes DescriptionCheck.call("Too short.", book: @book).errors, "too_short"
        assert_includes DescriptionCheck.call(("word " * 141).strip, book: @book).errors, "too_long"
      end

      test "counts words separated by non-breaking spaces" do
        text = (["word"] * 48).join("\u00A0")

        refute_includes DescriptionCheck.call(text, book: @book).errors, "too_short"
      end

      test "flags exactly 39 words as too_short and passes exactly 40" do
        refute_includes DescriptionCheck.call((["word"] * 40).join(" "), book: @book).errors, "too_short"
        assert_includes DescriptionCheck.call((["word"] * 39).join(" "), book: @book).errors, "too_short"
      end

      test "passes exactly 140 words and flags exactly 141 as too_long" do
        refute_includes DescriptionCheck.call((["word"] * 140).join(" "), book: @book).errors, "too_long"
        assert_includes DescriptionCheck.call((["word"] * 141).join(" "), book: @book).errors, "too_long"
      end

      test "reports every error at once" do
        result = DescriptionCheck.call("Short — https://x.example", book: @book)

        assert_equal %w[em_dash url too_short], result.errors
      end
    end
  end
end
