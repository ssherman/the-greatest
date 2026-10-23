require "test_helper"

module Services
  module Books
    module AlternateTitles
      class ResearchPromptTest < ActiveSupport::TestCase
        setup do
          @book = books_books(:war_and_peace)
          ::AlternateTitle.where(titleable: @book).delete_all
          @book.update_columns(alternate_titles: ["Voyna i mir", "Guerre et paix"])
          @row = ::AlternateTitle.create!(titleable: @book, title: "Guerre et paix", source: :legacy, status: :review,
            verdict: :not_same_work, category: :other_work, confidence: 0.85, reason: "Not a known French title.")
        end

        test "names the book, the title in question and the AI's view" do
          prompt = ResearchPrompt.call(@row)

          assert_includes prompt, "Title: #{@book.title}"
          assert_includes prompt, "Author(s): #{@book.authors.map(&:name).join(", ")}"
          assert_includes prompt, "Alternate title in question: \"Guerre et paix\""
          assert_includes prompt, "not same work (other work, confidence 0.85): Not a known French title."
          assert_includes prompt, "VERDICT: same work | different work | unsure"
        end

        test "lists the book's other titles but not the one in question" do
          prompt = ResearchPrompt.call(@row)

          assert_includes prompt, "Other titles we hold for this book: Voyna i mir"
          assert_not_includes prompt, "Voyna i mir; Guerre et paix"
        end

        test "a row the AI has not judged says so" do
          @row.update!(verdict: nil, category: nil, confidence: nil, reason: nil, status: :kept)

          assert_includes ResearchPrompt.call(@row), "Our AI reviewer's view: not reviewed yet"
        end
      end
    end
  end
end
