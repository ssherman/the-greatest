require "test_helper"

module Services
  module Text
    class PersonNameKeyTest < ActiveSupport::TestCase
      test ".call folds single-letter initials however they are spaced or stopped" do
        {
          "J.D. Salinger" => "j d salinger",
          "J. D. Salinger" => "j d salinger",
          "J D Salinger" => "j d salinger",
          "J. D Salinger" => "j d salinger",
          "j.d. salinger" => "j d salinger",
          "e.e. cummings" => "e e cummings",
          "J.R.R. Tolkien" => "j r r tolkien"
        }.each { |name, key| assert_equal key, PersonNameKey.call(name), name }
      end

      test ".call leaves every other word alone" do
        {
          "Martin Luther King Jr." => "martin luther king jr.",
          "JD Salinger" => "jd salinger",
          "J. Salinger" => "j salinger",
          "Malcolm X" => "malcolm x",
          "Leo Tolstoy" => "leo tolstoy"
        }.each { |name, key| assert_equal key, PersonNameKey.call(name), name }
      end

      test ".call keeps apart names that differ in more than how the initials are written" do
        salinger = PersonNameKey.call("J. D. Salinger")

        assert_not_equal salinger, PersonNameKey.call("J. Salinger")
        assert_not_equal salinger, PersonNameKey.call("Salinger")
        assert_not_equal salinger, PersonNameKey.call("JD Salinger")
        assert_not_equal PersonNameKey.call("King Jr."), PersonNameKey.call("King JR")
      end

      test ".call applies the finder's normalization first: quotes, Unicode spaces and case" do
        assert_equal "flann o'brien", PersonNameKey.call("FLANN O’BRIEN")
        assert_equal "j d salinger", PersonNameKey.call("J. D. Salinger")
      end

      test ".call folds an initial in a non-Latin script the same way" do
        assert_equal "а с пушкин", PersonNameKey.call("А.С. Пушкин")
      end

      test ".call returns nil for nil, empty and blank names" do
        assert_nil PersonNameKey.call(nil)
        assert_nil PersonNameKey.call("")
        assert_nil PersonNameKey.call("   ")
      end

      test ".all keys every name once, in order, and drops blanks" do
        assert_equal ["j d salinger", "jerome david salinger"],
          PersonNameKey.all(["J.D. Salinger", "J. D. Salinger", nil, "", "Jerome David Salinger"])
        assert_equal [], PersonNameKey.all(nil)
      end
    end
  end
end
