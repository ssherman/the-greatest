require "test_helper"

module Services
  module News
    class PlainTextTest < ActiveSupport::TestCase
      test ".call returns an empty string for nil" do
        assert_equal "", PlainText.call(nil)
      end

      test ".call separates adjacent blocks" do
        # Calling .text on the fragment instead yields "onetwo". This is the
        # whole reason this class exists.
        assert_equal "one two", PlainText.call("<p>one</p><p>two</p>")
      end

      test ".call separates legacy divs the same way as paragraphs" do
        assert_equal "one two", PlainText.call("<div>one</div><div>two</div>")
      end

      test ".call turns a br into a space rather than dropping it" do
        assert_equal "one two", PlainText.call("one<br>two")
      end

      test ".call separates list items" do
        assert_equal "a b", PlainText.call("<ul><li>a</li><li>b</li></ul>")
      end

      test ".call collapses runs of whitespace" do
        assert_equal "a b", PlainText.call("<p>a</p>\n\n   <p>b</p>")
      end

      test ".call keeps inline text unseparated" do
        assert_equal "a bold word", PlainText.call("<p>a <strong>bold</strong> word</p>")
      end
    end
  end
end
