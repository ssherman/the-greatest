# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class AuthorTest < ActiveSupport::TestCase
          setup do
            @book = books_books(:war_and_peace)
            @tolstoy = books_authors(:tolstoy)
            @garnett = books_authors(:garnett)
            @book.book_authors.destroy_all
            ::Books::BookAuthor.create!(book: @book, author: @tolstoy, position: 1)
            GoodreadsRebuild::Cohort.stubs(:trusted?).returns(false)
          end

          def verdict(after:, names: after.keys)
            ::Books::RepairVerdict.create!(kind: :reimport_author, subject_key: "reimport:author:#{@book.id}", decided_by: :rule,
              status: :approved,
              payload: {"book_id" => @book.id, "before_author_ids" => [@tolstoy.id], "row_author_names" => names, "after" => after})
          end

          def author_ids = @book.reload.book_authors.map(&:author_id)

          test "sets the authors in the rows' order and keeps the old ones in the payload" do
            verdict = verdict(after: {"Constance Garnett" => @garnett.id, "Leo Tolstoy" => @tolstoy.id})

            result = Author.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal [@garnett.id, @tolstoy.id], author_ids
            before = verdict.reload.payload["before_book_authors"]
            assert_equal [[@tolstoy.id, 1]], before.map { |ba| ba.values_at("author_id", "position") }
          end

          test "drops an author the rows do not credit" do
            Author.call(verdict: verdict(after: {"Constance Garnett" => @garnett.id}))

            assert_equal [@garnett.id], author_ids
          end

          test "creates an author for a nil entry and stores its id" do
            created = ::Books::Author.create!(name: "Brand New Writer")
            ::DataImporters::Books::Author::Importer.expects(:call).with { |args| args[:name] == "Brand New Writer" }
              .returns(stub(item: created, created?: true, all_errors: []))
            verdict = verdict(after: {"Leo Tolstoy" => @tolstoy.id, "Brand New Writer" => nil}, names: ["Leo Tolstoy", "Brand New Writer"])

            Author.call(verdict: verdict)

            assert_equal [@tolstoy.id, created.id], author_ids
            assert_equal [created.id], verdict.reload.payload["created_author_ids"]
          end

          test "an author the importer matched is linked but not recorded as created" do
            ::DataImporters::Books::Author::Importer.stubs(:call).returns(stub(item: @garnett, created?: false, all_errors: []))
            verdict = verdict(after: {"Constance Garnett" => nil})

            Author.call(verdict: verdict)

            assert_equal [@garnett.id], author_ids
            assert_empty Array(verdict.reload.payload["created_author_ids"])
          end

          test "a trusted book waits for an admin's review" do
            GoodreadsRebuild::Cohort.stubs(:trusted?).with(@book.id).returns(true)
            verdict = verdict(after: {"Constance Garnett" => @garnett.id})

            assert_equal :noop, Author.call(verdict: verdict).data[:outcome]
            assert_equal [@tolstoy.id], author_ids

            verdict.update!(reviewed_at: Time.current)
            assert_equal :applied, Author.call(verdict: verdict).data[:outcome]
            assert_equal [@garnett.id], author_ids
          end

          test "authors already in place are a final noop" do
            result = Author.call(verdict: verdict(after: {"Leo Tolstoy" => @tolstoy.id}))

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
          end

          test "an author id that no longer exists changes nothing" do
            result = Author.call(verdict: verdict(after: {"Gone" => 0}))

            assert_equal :noop, result.data[:outcome]
            assert_equal [@tolstoy.id], author_ids
          end

          test "a proposed verdict is not applied" do
            verdict = verdict(after: {"Constance Garnett" => @garnett.id})
            verdict.update!(status: :proposed)

            assert_equal :noop, Author.call(verdict: verdict).data[:outcome]
          end
        end
      end
    end
  end
end
