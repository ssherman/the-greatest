require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class FindAuthorDuplicatesTest < ActiveSupport::TestCase
        # Stands in for GroupSameAuthorsTask: records each call's lines, answers
        # with the given groups.
        class FakeTask
          class << self
            attr_accessor :groups, :success, :calls
          end

          def initialize(author_lines:, parent:)
            self.class.calls << author_lines
          end

          def call
            Services::Ai::Result.new(success: self.class.success, data: {groups: self.class.groups, reasoning: "test"},
              error: (self.class.success ? nil : "boom"), ai_chat: nil)
          end
        end

        setup do
          FakeTask.calls = []
          FakeTask.success = true
          FakeTask.groups = [{members: [1, 2], confidence: "high"}]
          @first = ::Books::Author.create!(name: "J.D. Quillfeather")
          @second = ::Books::Author.create!(name: "J. D. Quillfeather")
          ::Books::BookAuthor.create!(book: books_books(:war_and_peace), author: @second)
        end

        def find
          FindAuthorDuplicates.call(task_class: FakeTask)
        end

        def quill_verdict
          ::Books::RepairVerdict.merge_authors.find_by!(subject_key: "authors:#{[@first.id, @second.id].minmax.join(":")}")
        end

        test "sends each name group once, with names that differ only in punctuation and spacing grouped together" do
          ::Books::Author.create!(name: "Someone Unique Entirely")

          result = find

          quill = FakeTask.calls.select { |lines| lines.any? { |line| line.include?("Quillfeather") } }
          assert_equal 1, quill.size
          assert_equal 2, quill.first.size
          assert_equal result.data[:ai_calls], FakeTask.calls.size
          refute(FakeTask.calls.flatten.any? { |line| line.include?("Someone Unique Entirely") })
        end

        test "a high-confidence group with no conflicts is an approved merge into the author with more books" do
          find

          verdict = quill_verdict
          assert_predicate verdict, :approved?
          assert_predicate verdict, :decided_by_ai?
          assert_equal [@first.id, @second.id], [verdict.payload["source_id"], verdict.payload["target_id"]]
          assert_equal [], verdict.payload["conflicts"]
        end

        test "different birth years make it a proposal" do
          @first.update!(birth_year: 1950)
          @second.update!(birth_year: 1951)

          find

          assert_predicate quill_verdict, :proposed?
          assert_equal ["birth years differ (1950 vs 1951)"], quill_verdict.payload["conflicts"]
        end

        test "different Wikidata ids make it a proposal" do
          ::Identifier.create!(identifiable: @first, identifier_type: :books_author_wikidata_qid, value: "Q1")
          ::Identifier.create!(identifiable: @second, identifier_type: :books_author_wikidata_qid, value: "Q2")

          find

          assert_equal ["different books_author_wikidata_qid"], quill_verdict.payload["conflicts"]
          assert_predicate quill_verdict, :proposed?
        end

        test "a medium-confidence group is a proposal" do
          FakeTask.groups = [{members: [1, 2], confidence: "medium"}]

          find

          assert_predicate quill_verdict, :proposed?
        end

        test "a pair an admin marked not a duplicate is not proposed again" do
          ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Author", ids: [@first.id, @second.id], source: :human)
          ::DuplicateCandidate.where(item_type: "Books::Author", item_a_id: [@first.id, @second.id].min).sole.update!(status: :not_duplicate)

          find

          assert_nil ::Books::RepairVerdict.find_by(subject_key: "authors:#{[@first.id, @second.id].minmax.join(":")}")
        end

        test "a group over the limit is not sent" do
          Rails.configuration.x.goodreads_replay.stubs(:max_author_group).returns(1)

          result = find

          assert_empty FakeTask.calls
          assert_operator result.data[:tally][:too_large], :>=, 1
        end

        test "a failed AI call records nothing and is counted" do
          FakeTask.success = false

          result = find

          assert_equal 0, ::Books::RepairVerdict.count
          assert_operator result.data[:tally][:ai_failed], :>=, 1
        end

        test "finds only; merges nothing" do
          assert_no_difference(-> { ::Books::Author.count }) { find }
        end
      end
    end
  end
end
