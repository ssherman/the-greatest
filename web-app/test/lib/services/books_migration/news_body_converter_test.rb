require "test_helper"

module Services
  module BooksMigration
    class NewsBodyConverterTest < ActiveSupport::TestCase
      test ".call converts a Trix div to a paragraph" do
        assert_equal "one\n\ntwo", NewsBodyConverter.call("<div>one</div><div>two</div>").strip
      end

      test ".call converts strong to bold" do
        assert_includes NewsBodyConverter.call("<div><strong>hi</strong></div>"), "**hi**"
      end

      test ".call converts links" do
        html = '<div><a href="https://x.test">label</a></div>'

        assert_includes NewsBodyConverter.call(html), "[label](https://x.test)"
      end

      test ".call converts ordered lists" do
        assert_includes NewsBodyConverter.call("<ol><li>a</li><li>b</li></ol>"), "1. a"
      end

      test ".call removes the stray space reverse_markdown inserts before punctuation" do
        # reverse_markdown turns "<strong>x</strong>:" into "**x** :", which
        # renders visibly wrong. Measured: this affects 2 of the 31 real posts.
        assert_includes NewsBodyConverter.call("<div><strong>top 5</strong>:</div>"), "**top 5**:"
        assert_not_includes NewsBodyConverter.call("<div><strong>top 5</strong>:</div>"), "** :"
      end

      test ".call leaves a legitimate space before a colon alone" do
        assert_includes NewsBodyConverter.call("<div>a word : spaced</div>"), "a word : spaced"
      end

      test ".round_trips? is true when the rendered Markdown carries the same text" do
        assert NewsBodyConverter.round_trips?("<div>one</div><div>two</div>")
      end

      test ".round_trips? compares block-aware text on both sides" do
        # A legacy <div>-per-paragraph body renders back as <p>-per-paragraph.
        # Comparing raw .text would report a mismatch on every multi-block post.
        assert NewsBodyConverter.round_trips?("<div>alpha</div><div>beta</div>")
      end

      test ".round_trips? is false when text is lost" do
        NewsBodyConverter.stubs(:call).returns("only the first bit")

        assert_not NewsBodyConverter.round_trips?("<div>only the first bit</div><div>and more</div>")
      end
    end
  end
end
