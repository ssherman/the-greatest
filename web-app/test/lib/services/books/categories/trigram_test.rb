require "test_helper"

module Services
  module Books
    module Categories
      class TrigramTest < ActiveSupport::TestCase
        test "identical strings score 1.0, ignoring case and punctuation" do
          assert_equal 1.0, Trigram.similarity("Paris", "paris!")
        end

        test "disjoint strings score 0.0" do
          assert_equal 0.0, Trigram.similarity("abc", "xyz")
        end

        test "empty input scores 0.0" do
          assert_equal 0.0, Trigram.similarity("", "")
          assert_equal 0.0, Trigram.word_similarity("", "Paris")
        end

        test "word_similarity finds a whole word inside a longer name" do
          assert_operator Trigram.word_similarity("Paris", "Parisian Suburbs"), :>, 0.5
          assert_operator Trigram.similarity("Paris", "Parisian Suburbs"), :<, 0.3
        end
      end
    end
  end
end
