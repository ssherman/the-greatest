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

      SOURCE = "Ernest Miller Hemingway was an American novelist, short-story writer and journalist. " \
        "Known for an economical, understated style, he influenced later twentieth-century fiction."

      test "a draft sharing eight consecutive words with its source fails as copied" do
        draft = "#{CLEAN} He was an American novelist, short-story writer and editor from Illinois."

        result = DescriptionCheck.call(draft, source_text: SOURCE)

        refute result.success?
        assert_includes result.errors, "copied"
      end

      test "seven shared words in a row are not a copy" do
        draft = "#{CLEAN} Hemingway became an American novelist, short-story writer and editor in Paris."

        assert_not_includes DescriptionCheck.call(draft, source_text: SOURCE).errors, "copied"
      end

      test "case and punctuation do not hide a copy" do
        draft = "#{CLEAN} WAS AN AMERICAN NOVELIST; SHORT STORY WRITER, AND JOURNALIST."

        assert_includes DescriptionCheck.call(draft, source_text: SOURCE).errors, "copied"
      end

      test "without source text there is no copy check" do
        assert_not_includes DescriptionCheck.call("#{CLEAN} #{SOURCE}").errors, "copied"
      end

      SOURCE2 = "Rabindranath Tagore (রবীন্দ্রনাথ ঠাকুর) was a Bengali poet and composer."

      test "a native-script name split by combining marks is not mistaken for a copy" do
        draft = "#{CLEAN} Tagore, রবীন্দ্রনাথ ঠাকুর in Bengali, wrote many songs."

        assert_not_includes DescriptionCheck.call(draft, source_text: SOURCE2).errors, "copied"
      end

      SOURCE3 = "Sacks is best known for The Man Who Mistook His Wife for a Hat, a collection of case studies."

      test "a shared work title fails as copied unless exempted" do
        draft = "#{CLEAN} His book The Man Who Mistook His Wife for a Hat gathers case histories."

        assert_includes DescriptionCheck.call(draft, source_text: SOURCE3).errors, "copied"
        refute_includes DescriptionCheck.call(draft, source_text: SOURCE3, exempt_phrases: ["The Man Who Mistook His Wife for a Hat"]).errors, "copied"
      end

      test "an exempt title does not hide copying elsewhere" do
        draft = "#{CLEAN} He was an American novelist, short-story writer and editor from Illinois."

        result = DescriptionCheck.call(draft, source_text: SOURCE, exempt_phrases: ["Hemingway"])

        assert_includes result.errors, "copied"
      end
    end
  end
end
