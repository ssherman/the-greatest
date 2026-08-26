require "test_helper"

module Services
  module Corrections
    class TargetsTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:war_and_peace)
      end

      test "resolves the column target" do
        assert_equal Targets::Column, Targets.for(:column)
      end

      test "resolves the description target" do
        assert_equal Targets::PrimaryDescription, Targets.for(:description)
      end

      test "raises on an unknown target" do
        assert_raises(ArgumentError) { Targets.for(:nonsense) }
      end

      test "column reads the current value" do
        assert_equal "War and Peace", Targets::Column.read(@book, "title")
      end

      test "column writes without saving" do
        Targets::Column.write(@book, "title", "War & Peace")
        assert_equal ["War & Peace", "War and Peace"], [@book.title, @book.reload.title]
      end

      test "description reads the resolved primary description" do
        assert_equal @book.primary_description.content,
          Targets::PrimaryDescription.read(@book, "description")
      end

      test "description writes a manual row that the resolver then prefers" do
        Targets::PrimaryDescription.write(@book, "description", "A corrected summary.")
        @book.save!

        row = @book.descriptions.reload.find { |d| d.source == "manual" }
        assert_equal "A corrected summary.", row.content
        # manual is first in Descriptions::SourcePriority::ORDER, so it wins
        # without anyone setting rank.
        assert_equal "A corrected summary.", @book.reload.primary_description.content
      end

      test "description updates the existing manual row rather than adding a second" do
        Targets::PrimaryDescription.write(@book, "description", "First.")
        @book.save!
        Targets::PrimaryDescription.write(@book.reload, "description", "Second.")
        @book.save!

        manual = @book.descriptions.reload.select { |d| d.source == "manual" }
        assert_equal ["Second."], manual.map(&:content)
      end
    end
  end
end
