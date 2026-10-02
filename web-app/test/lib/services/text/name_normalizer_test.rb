require "test_helper"

module Services
  module Text
    class NameNormalizerTest < ActiveSupport::TestCase
      test ".call returns nil for nil and empty string for empty string" do
        assert_nil NameNormalizer.call(nil)
        assert_equal "", NameNormalizer.call("")
      end

      test ".call folds a narrow no-break space to a plain space" do
        assert_equal "Kathleen Alcott", NameNormalizer.call("Kathleen Alcott")
      end

      test ".call folds a no-break space, an em space and a zero-width space" do
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo Tolstoy")
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo Tolstoy")
        assert_equal "Leo Tolstoy", NameNormalizer.call("Leo​ Tolstoy")
      end

      test ".call collapses runs of spaces and strips the ends" do
        assert_equal "War and Peace", NameNormalizer.call("  War   and   Peace  ")
      end

      test ".call applies NFKC so a ligature and a fullwidth letter compare equal to ASCII" do
        assert_equal "fine", NameNormalizer.call("ﬁne")
        assert_equal "A", NameNormalizer.call("Ａ")
      end

      test ".call leaves ordinary text alone" do
        assert_equal "Crime and Punishment", NameNormalizer.call("Crime and Punishment")
      end
    end
  end
end
