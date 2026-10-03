# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Books
        # The prompts' wording before the list moved into one constant, pinned
        # so the move changed no prompt.
        class BannedWordsTest < ActiveSupport::TestCase
          PROSE = "delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, " \
            'navigate, resonate, profound, haunting, luminous, or "explores themes of"'
          LIST = PROSE.sub(', or "', ', "')

          test "one list, in a writing rule's form and a review code's form" do
            assert_equal [PROSE, LIST], [BannedWords.prose, BannedWords.list]
          end

          test "both writing prompts and both review prompts carry it" do
            author = books_authors(:tolstoy)
            book = books_books(:war_and_peace)
            writers = [
              AuthorFactsTask.new(parent: author, records: stub(wikidata: nil, viaf: nil, lead: nil)),
              BookFactsTask.new(parent: book)
            ]
            reviewers = [
              AuthorDescriptionReviewTask.new(parent: author, description: "A novelist."),
              DescriptionReviewTask.new(parent: book, description: "A novel.")
            ]

            writers.each { |task| assert_includes task.send(:system_message), "Plain words. Do not use: #{PROSE}." }
            reviewers.each { |task| assert_includes task.send(:system_message), "- banned_word: #{LIST}\n" }
          end
        end
      end
    end
  end
end
