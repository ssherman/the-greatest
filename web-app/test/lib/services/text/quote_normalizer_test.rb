require "test_helper"

module Services
  module Text
    class QuoteNormalizerTest < ActiveSupport::TestCase
      test ".call returns nil when input is nil" do
        assert_nil QuoteNormalizer.call(nil)
      end

      test ".call returns empty string when input is empty string" do
        assert_equal "", QuoteNormalizer.call("")
      end

      test ".call returns unchanged text when no quotes present" do
        text = "Hello World"
        assert_equal "Hello World", QuoteNormalizer.call(text)
      end

      test ".call normalizes left single quote to straight apostrophe" do
        text = "\u2018Hello"
        assert_equal "'Hello", QuoteNormalizer.call(text)
      end

      test ".call normalizes right single quote to straight apostrophe" do
        text = "Don\u2019t"
        assert_equal "Don't", QuoteNormalizer.call(text)
      end

      test ".call normalizes left double quote to straight quote" do
        text = "\u201CHello\u201D"
        assert_equal "\"Hello\"", QuoteNormalizer.call(text)
      end

      test ".call normalizes right double quote to straight quote" do
        text = "Say \u201CHello\u201D"
        assert_equal "Say \"Hello\"", QuoteNormalizer.call(text)
      end

      test ".call normalizes all quote types in same string" do
        text = "\u2018Don\u2019t Stop Believin\u2019\u201D on \u201CThe Journey\u201D"
        expected = "'Don't Stop Believin'\" on \"The Journey\""
        assert_equal expected, QuoteNormalizer.call(text)
      end

      test ".call handles multiple occurrences of same quote type" do
        text = "\u2018word\u2019 and \u2018another\u2019"
        assert_equal "'word' and 'another'", QuoteNormalizer.call(text)
      end

      test ".call preserves already normalized quotes" do
        text = "Don't Stop \"Believin'\""
        assert_equal "Don't Stop \"Believin'\"", QuoteNormalizer.call(text)
      end

      test ".call handles mixed smart and straight quotes" do
        text = "Don't Stop \u201CBelievin'\u201D"
        assert_equal "Don't Stop \"Believin'\"", QuoteNormalizer.call(text)
      end
    end
  end
end
