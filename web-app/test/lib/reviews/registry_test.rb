require "test_helper"

module Reviews
  class RegistryTest < ActiveSupport::TestCase
    test "resolves the books domain to its reviewable types" do
      assert_equal ["Books::Book"], Registry.types_for(:books)
      assert_equal [::Books::Book], Registry.classes_for(:books)
    end

    test "a domain with no reviewable types resolves to empty" do
      assert_empty Registry.types_for(:music)
      assert_empty Registry.classes_for(:nope)
    end

    test "accepts a string domain as well as a symbol" do
      assert_equal ["Books::Book"], Registry.types_for("books")
    end

    test "allowed? gates arbitrary user-supplied types" do
      assert Registry.allowed?("Books::Book")
      refute Registry.allowed?("User")
      refute Registry.allowed?(nil)
    end
  end
end
