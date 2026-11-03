# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class CheckAuthorTest < ActiveSupport::TestCase
        setup do
          @book = ::Books::Book.create!(title: "Breaking Free")
          @tolstoy = books_authors(:tolstoy)
          @book.book_authors.create!(author: @tolstoy, position: 1)
          @task_class = mock("task_class")
          @finder = mock("finder")
          GoodreadsRebuild::Cohort.stubs(:trusted?).returns(false)
          @serial = 0
        end

        def edition(primary, additional: [])
          ::Books::GoodreadsEdition.create!(goodreads_book_id: 970_000 + (@serial += 1), signature: "ca-#{@serial}", title: "Breaking Free",
            primary_author: primary, additional_authors: additional).tap do |edition|
            ::Books::RepairVerdict.create!(kind: :reimport_row, subject_key: "reimport:row:ca:#{@serial}", decided_by: :rule, status: :approved,
              applied_at: Time.current, payload: {"to_book_id" => @book.id, "goodreads_edition_id" => edition.id})
          end
        end

        def ai(*matches)
          task = mock("task")
          task.stubs(:call).returns(Services::Ai::Result.new(success: true, data: {matches: matches, reasoning: ""}))
          task
        end

        def found(record, confidence: :high, decided_by: :ai)
          DataImporters::Match.new(outcome: :matched, record: record, confidence: confidence, decided_by: decided_by)
        end

        def none(confidence: :high) = DataImporters::Match.new(outcome: :unmatched, confidence: confidence, decided_by: :rule)

        def call = CheckAuthor.call(book: @book, author_finder: @finder, task_class: @task_class)

        test "a book no applied row points at has nothing to check" do
          result = call

          assert_equal :agrees, result.data[:outcome]
          assert_nil result.data[:verdict]
        end

        test "agrees when every row name matches a current author by name key, without the AI or the finder" do
          edition("Lev Tolstoy")
          @task_class.expects(:new).never
          @finder.expects(:call).never

          assert_equal :agrees, call.data[:outcome]
          assert_equal 0, ::Books::RepairVerdict.reimport_author.count
        end

        test "agrees when the AI says the row name is the current author" do
          edition("Count L. N. Tolstoi")
          @task_class.expects(:new).returns(ai({export_name: "Count L. N. Tolstoi", author_number: 1, confidence: "high"}))
          @finder.expects(:call).never

          assert_equal :agrees, call.data[:outcome]
        end

        test "a translator among the additional authors is not a credited author" do
          edition("Leo Tolstoy", additional: ["Constance Garnett"])
          @task_class.expects(:new).never

          assert_equal :agrees, call.data[:outcome]
        end

        test "disagrees and links a catalog author the finder confirms; auto-approved on an import-made book" do
          garnett = books_authors(:garnett)
          edition("Constance Garnett")
          @task_class.expects(:new).returns(ai({export_name: "Constance Garnett", author_number: 1, confidence: "none"}))
          @finder.expects(:call).with { |args| args[:query].name == "Constance Garnett" && args[:verify] == true }.returns(found(garnett))

          result = call
          verdict = result.data[:verdict]

          assert_equal :recorded, result.data[:outcome]
          assert verdict.approved?
          assert_equal "reimport:author:#{@book.id}", verdict.subject_key
          assert_equal [@tolstoy.id], verdict.payload["before_author_ids"]
          assert_equal ["Constance Garnett"], verdict.payload["row_author_names"]
          assert_equal({"Constance Garnett" => garnett.id}, verdict.payload["after"])
        end

        test "disagrees with no catalog author found: create, still auto-approved when the finder is sure" do
          edition("Brand New Writer")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(none)

          verdict = call.data[:verdict]

          assert_equal({"Brand New Writer" => nil}, verdict.payload["after"])
          assert verdict.approved?
        end

        test "a finder pick below high is not accepted and the verdict is proposed" do
          edition("Constance Garnett")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(found(books_authors(:garnett), confidence: :medium))

          verdict = call.data[:verdict]

          assert_equal({"Constance Garnett" => nil}, verdict.payload["after"])
          assert verdict.proposed?
        end

        test "an unsure finder (create with medium confidence) leaves the verdict proposed" do
          edition("Brand New Writer")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(none(confidence: :medium))

          assert call.data[:verdict].proposed?
        end

        test "a rule-only exact-name match keeps its candidate but leaves the verdict proposed" do
          garnett = books_authors(:garnett)
          edition("Constance Garnett")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(found(garnett, decided_by: :rule))

          verdict = call.data[:verdict]

          assert_equal({"Constance Garnett" => garnett.id}, verdict.payload["after"])
          assert verdict.proposed?
        end

        test "an applied verdict is never overwritten by a later run" do
          edition("Constance Garnett")
          @task_class.stubs(:new).returns(ai)
          @finder.stubs(:call).returns(none)
          verdict = call.data[:verdict]
          verdict.update_columns(applied_at: Time.current, payload: verdict.payload.merge("before_book_authors" => [[1]], "created_author_ids" => [7]))
          @finder.stubs(:call).returns(found(books_authors(:garnett)))

          result = call

          assert_equal :kept, result.data[:outcome]
          payload = verdict.reload.payload
          assert_equal [[1]], payload["before_book_authors"]
          assert_equal [7], payload["created_author_ids"]
          assert_equal({"Constance Garnett" => nil}, payload["after"])
        end

        test "an agreeing run supersedes an earlier unapplied proposal" do
          edition("Constance Garnett")
          @task_class.stubs(:new).returns(ai)
          @finder.stubs(:call).returns(none(confidence: :medium))
          verdict = call.data[:verdict]
          @book.book_authors.destroy_all
          @book.book_authors.create!(author: books_authors(:garnett), position: 1)

          assert_equal :agrees, call.data[:outcome]
          assert verdict.reload.superseded_at.present?
        end

        test "an additional author already linked to a primary name's author is not listed twice" do
          edition("Brand New Writer", additional: ["Lev N. Tolstoy"])
          edition("Leo Tolstoy", additional: ["Lev N. Tolstoy"])
          @task_class.stubs(:new).returns(ai({export_name: "Lev N. Tolstoy", author_number: 1, confidence: "high"}))
          @finder.stubs(:call).returns(none)

          verdict = call.data[:verdict]

          assert_equal ["Brand New Writer", "Leo Tolstoy"], verdict.payload["row_author_names"]
        end

        test "a trusted book is always proposed" do
          GoodreadsRebuild::Cohort.stubs(:trusted?).with(@book.id).returns(true)
          edition("Constance Garnett")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(found(books_authors(:garnett)))

          assert call.data[:verdict].proposed?
        end

        test "a book this run created is import-made, not trusted, though its id lies above the post-import range" do
          GoodreadsRebuild::Cohort.stubs(:trusted?).with(@book.id).returns(true)
          ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:1", decided_by: :ai, status: :approved,
            applied_at: Time.current, payload: {"outcome" => "create", "created_book_id" => @book.id})
          edition("Constance Garnett")
          @task_class.expects(:new).returns(ai)
          @finder.expects(:call).returns(found(books_authors(:garnett)))

          assert call.data[:verdict].approved?
        end

        test "row names are the editions' primary authors, most common first, and an additional author joins only when the AI confirms it" do
          edition("Constance Garnett")
          edition("Brand New Writer", additional: ["Count L. N. Tolstoi"])
          edition("Brand New Writer")
          @task_class.expects(:new).twice.returns(ai, ai({export_name: "Count L. N. Tolstoi", author_number: 1, confidence: "high"}))
          @finder.stubs(:call).returns(none)

          verdict = call.data[:verdict]

          assert_equal ["Brand New Writer", "Constance Garnett", "Count L. N. Tolstoi"], verdict.payload["row_author_names"]
          assert_equal({"Brand New Writer" => nil, "Constance Garnett" => nil, "Count L. N. Tolstoi" => @tolstoy.id}, verdict.payload["after"])
        end

        test "an AI failure fails the result and records nothing" do
          edition("Constance Garnett")
          @task_class.expects(:new).returns(stub(call: Services::Ai::Result.new(success: false, error: "down", data: {})))

          result = call

          refute result.success?
          assert_equal 0, ::Books::RepairVerdict.reimport_author.count
        end

        test "running again keeps a rejected verdict rejected" do
          edition("Constance Garnett")
          @task_class.stubs(:new).returns(ai)
          @finder.stubs(:call).returns(none)
          call.data[:verdict].update!(status: :rejected)

          assert_equal :kept, call.data[:outcome]
        end

        test "stale_alternates lists alternate names that are another author's name and that no row of the author's books names" do
          author = ::Books::Author.create!(name: "Pen Writer", alternate_names: ["Leo Tolstoy", "Pennington", "lev tolstoy"])
          @book.book_authors.create!(author: author, position: 2)

          assert_equal ["Leo Tolstoy"], CheckAuthor.stale_alternates(author)
        end

        test "an alternate name one of the author's rows names is not stale" do
          author = ::Books::Author.create!(name: "Pen Writer", alternate_names: ["Leo Tolstoy"])
          @book.book_authors.create!(author: author, position: 2)
          edition("Leo Tolstoy")

          assert_empty CheckAuthor.stale_alternates(author)
        end
      end
    end
  end
end
