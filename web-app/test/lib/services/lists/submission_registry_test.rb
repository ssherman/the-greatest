require "test_helper"

module Services
  module Lists
    class SubmissionRegistryTest < ActiveSupport::TestCase
      test "books accepts one list type" do
        assert_equal [::Books::List], SubmissionRegistry.types_for(:books)
      end

      test "games accepts one list type" do
        assert_equal [::Games::List], SubmissionRegistry.types_for(:games)
      end

      test "music accepts albums and songs" do
        assert_equal [::Music::Albums::List, ::Music::Songs::List],
          SubmissionRegistry.types_for(:music)
      end

      test "an unknown domain accepts nothing" do
        assert_equal [], SubmissionRegistry.types_for(:unrecognised)
        assert_equal [], SubmissionRegistry.types_for(nil)
      end

      test "resolve returns the class when the domain allows it" do
        assert_equal ::Books::List, SubmissionRegistry.resolve(:books, "Books::List")
      end

      test "resolve returns nil for a type the domain does not allow" do
        assert_nil SubmissionRegistry.resolve(:books, "Music::Albums::List")
      end

      test "resolve returns nil for an unknown constant and does not constantize it" do
        assert_nil SubmissionRegistry.resolve(:books, "Kernel")
        assert_nil SubmissionRegistry.resolve(:books, "NoSuchThing")
      end

      test "label_for names each type for the picker" do
        assert_equal "Album List", SubmissionRegistry.label_for(::Music::Albums::List)
        assert_equal "Song List", SubmissionRegistry.label_for(::Music::Songs::List)
      end

      test "domain_for maps a list class back to its domain" do
        assert_equal :books, SubmissionRegistry.domain_for(::Books::List)
        assert_equal :games, SubmissionRegistry.domain_for(::Games::List)
        assert_equal :music, SubmissionRegistry.domain_for(::Music::Albums::List)
        assert_equal :music, SubmissionRegistry.domain_for(::Music::Songs::List)
      end

      test "domain_for returns nil for a class no domain accepts" do
        assert_nil SubmissionRegistry.domain_for(::List)
      end
    end
  end
end
