# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    module Wizard
      module Core
        class ImportRowsTest < ActiveSupport::TestCase
          include ListWizardHelper
          include GoodreadsImportHelper

          SOURCE_VERSION = {"source" => "openlibrary", "dump_date" => "2026-07-31", "normalizer_version" => 1,
                            "pipeline_version" => 1, "matcher_version" => 2}.freeze

          setup do
            @list = wizard_list
            @adapter = ::Services::Lists::Wizard::Books::Adapter.new
          end

          def create_row(position, title, authors: ["Wren Halloway"], work: nil)
            row = wizard_row(@list, position: position, title: title, authors: authors,
              wizard: {bucket: "create", ol_work_key: work, ol_keys: Array(work), matched_at: Time.current.iso8601})
            decision = wizard_match(subject: row, outcome: :unmatched, confidence: :high, decided_by: :rule).decision
            RowState.new(row).merge("match_decision_id" => decision.id)
            row.save!
            row
          end

          def work_record(key, title)
            {"key" => {"source" => "openlibrary", "key" => key}, "redirected_from" => [], "title" => title, "subtitle" => nil,
             "description" => nil, "subjects" => [], "year_evidence" => nil, "popularity" => nil,
             "authors" => [{"key" => {"source" => "openlibrary", "key" => "OL900A"}, "name" => "Wren Halloway"}]}
          end

          def stub_works
            candidates = [["OL901W", "The Salt Ledger"], ["OL902W", "A Winter of Crows"]].map do |key, title|
              {"key" => {"source" => "openlibrary", "key" => key}, "score" => 0.8, "rules" => ["title_author"], "margin" => 0.1,
               "verdict" => "abstain", "evidence" => {}, "conflicts" => [], "diff" => [], "record" => work_record(key, title)}
            end
            body = {"source_version" => SOURCE_VERSION, "data" => {
              "decision" => {"verdict" => "abstain", "key" => nil, "score" => 0.0, "margin" => 0.0, "reason" => "test"},
              "guards_tripped" => [], "volume_guards_tripped" => [], "candidates" => candidates
            }}
            stub_request(:post, "#{OPEN_LIBRARY_URL}/resolve").to_return(status: 200, body: body.to_json)
            author = {"source_version" => SOURCE_VERSION, "data" => {"key" => {"source" => "openlibrary", "key" => "OL900A"},
                                                                     "redirected_from" => [], "name" => "Wren Halloway", "alternate_names" => [], "birth_year" => nil, "death_year" => nil}}
            stub_request(:get, "#{OPEN_LIBRARY_URL}/authors/OL900A").to_return(status: 200, body: author.to_json)
          end

          test "a create row is created, linked, verified and settled, and Import completes" do
            book = books_books(:war_and_peace)
            row = create_row(1, "War and Peace", work: "OL5W")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).with(row).returns(book)

            assert_equal 1, ImportRows.call(list: @list, adapter: @adapter)

            state = RowState.new(row.reload)
            assert_equal [book.id, true, "matched", "created", true], [row.listable_id, row.verified, state.bucket, state.import_result, state.settled?]
            assert_equal "completed", @list.reload.wizard_manager.step_status("import")
          end

          test "a book found by the re-check is linked and marked changed_since_match, not created and not flagged" do
            book = books_books(:crime_and_punishment)
            row = create_row(1, "Crime and Punishment", work: "OL262758W")
            @adapter.expects(:create).never

            ImportRows.call(list: @list, adapter: @adapter)

            state = RowState.new(row.reload)
            assert_equal [book.id, "matched", "linked_existing", ["changed_since_match"]],
              [row.listable_id, state.bucket, state.import_result, state.reasons]
          end

          test "a failing row is flagged import_failed with the error and the next row still imports" do
            bad = create_row(1, "Bad Row")
            good = create_row(2, "Good Row")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.stubs(:create).with(bad).raises(StandardError, "open library exploded")
            @adapter.stubs(:create).with(good).returns(books_books(:got))

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal ["flagged", ["import_failed"], "open library exploded"],
              RowState.new(bad.reload).data.values_at("bucket", "reasons", "import_error")
            assert_equal books_books(:got).id, good.reload.listable_id
            assert_equal 1, @list.reload.wizard_manager.step_metadata("import")["failed_count"]
          end

          test "a found book another row already holds flags the row on_list_twice" do
            book = books_books(:crime_and_punishment)
            wizard_row(@list, position: 9, title: "Crime and Punishment", listable: book, wizard: {bucket: "matched", settled: true})
            row = create_row(1, "Crime and Punishment", work: "OL262758W")

            ImportRows.call(list: @list, adapter: @adapter)

            assert_nil row.reload.listable_id
            assert_equal ["flagged", ["on_list_twice"]], RowState.new(row).data.values_at("bucket", "reasons")
          end

          test "removed rows are deleted when Import finishes; other rows stay" do
            removed = wizard_row(@list, position: 1, title: "Made Up", wizard: {bucket: "removed", settled: true})
            flagged = wizard_row(@list, position: 2, title: "Unsure", wizard: {bucket: "flagged", reasons: ["unsure"]})

            ImportRows.call(list: @list, adapter: @adapter)

            assert_not ::ListItem.exists?(removed.id)
            assert ::ListItem.exists?(flagged.id)
          end

          test "a second import run creates nothing for rows it already created" do
            row = create_row(1, "War and Peace", work: "OL5W")
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).once.returns(books_books(:war_and_peace))

            ImportRows.call(list: @list, adapter: @adapter)
            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal books_books(:war_and_peace).id, row.reload.listable_id
          end

          test "the claim alone leaves the step stamped, so a running Import is not read as stalled" do
            @list.wizard_manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "run-1"})
            ::Services::Lists::Wizard::Books::StateManager.any_instance.stubs(:write_step!)

            ImportRows.call(list: @list, adapter: @adapter, run_id: "run-1")

            assert @list.reload.wizard_state.dig("steps", "import", "updated_at").present?
          end

          test "a second start is refused while another run owns the step" do
            row = create_row(1, "War and Peace", work: "OL5W")
            @list.wizard_manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "other-run"})
            @adapter.expects(:create).never

            assert_nil ImportRows.call(list: @list, adapter: @adapter, run_id: "late-run")

            assert_nil row.reload.listable_id
            assert_equal "other-run", @list.reload.wizard_manager.step_metadata("import")["run_id"]
          end

          test "the run that was started is the one that runs" do
            create_row(1, "War and Peace", work: "OL5W")
            @list.wizard_manager.write_step!(step: "import", status: "running", metadata: {"run_id" => "run-1"})
            @adapter.stubs(:recheck).returns(nil)
            @adapter.expects(:create).once.returns(books_books(:war_and_peace))

            assert_equal 1, ImportRows.call(list: @list, adapter: @adapter, run_id: "run-1")
          end

          test "a row another run created after this run listed it is skipped" do
            first = create_row(1, "War and Peace", work: "OL5W")
            second = create_row(2, "A Game of Thrones", work: "OL6W")
            got = books_books(:got)
            created = []
            @adapter.stubs(:recheck).returns(nil)
            @adapter.define_singleton_method(:create) do |item, **|
              created << item.id
              # Meanwhile a concurrent run imports the second row.
              other = ::ListItem.find(second.id)
              ::Services::Lists::Wizard::Core::RowState.new(other).merge("bucket" => "matched", "import_result" => "created", "settled" => true)
              other.update!(listable: got, verified: true)
              ::Books::Book.find_by!(title: "War and Peace")
            end

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal [first.id], created
            assert_equal got.id, second.reload.listable_id
          end

          test "a text row whose title differs only in its apostrophe finds the book the first row made" do
            stub_resolution_services
            curly = create_row(1, "The Hitchhiker’s Guide", authors: ["Douglas Adams"])
            straight = create_row(2, "The Hitchhiker's Guide", authors: ["Douglas Adams"])

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal 1, ::Books::Book.where(title: ["The Hitchhiker’s Guide", "The Hitchhiker's Guide"]).count
            assert curly.reload.listable_id.present?
            assert_equal ["flagged", ["on_list_twice"]], RowState.new(straight.reload).data.values_at("bucket", "reasons")
          end

          test "an admin-chosen work the service did not accept still lands on the new book" do
            stub_resolution_services # /resolve abstains with no candidates
            row = create_row(1, "The Chosen", authors: ["Chaim Potok"], work: "OL55W")

            ImportRows.call(list: @list, adapter: @adapter)

            book = row.reload.listable
            assert book.identifiers.exists?(identifier_type: :books_work_openlibrary_id, value: "OL55W")
            assert_not book.provisional?
          end

          test "two books by an author we do not hold create exactly one author" do
            stub_resolution_services
            stub_works
            first = create_row(1, "The Salt Ledger", work: "OL901W")
            second = create_row(2, "A Winter of Crows", work: "OL902W")

            ImportRows.call(list: @list, adapter: @adapter)

            authors = ::Books::Author.where(name: "Wren Halloway")
            assert_equal 1, authors.count
            assert_equal [[authors.first], [authors.first]], [first.reload.listable.authors.to_a, second.reload.listable.authors.to_a]
          end

          test "the same when one book comes from Open Library and one from the row's text" do
            stub_resolution_services
            stub_works
            from_work = create_row(1, "The Salt Ledger", work: "OL901W")
            from_text = create_row(2, "A Winter of Crows")

            ImportRows.call(list: @list, adapter: @adapter)

            authors = ::Books::Author.where(name: "Wren Halloway")
            assert_equal 1, authors.count
            assert_equal [[authors.first], [authors.first]], [from_work.reload.listable.authors.to_a, from_text.reload.listable.authors.to_a]
          end

          test "and when both come from the rows' text" do
            stub_resolution_services
            create_row(1, "The Salt Ledger")
            create_row(2, "A Winter of Crows")

            ImportRows.call(list: @list, adapter: @adapter)

            assert_equal 1, ::Books::Author.where(name: "Wren Halloway").count
          end

          test "rows that are not in the create bucket are never sent to create" do
            wizard_row(@list, position: 1, title: "Flagged One", authors: ["A B"], wizard: {bucket: "flagged", reasons: ["ai_only_pick"]})
            wizard_row(@list, position: 2, title: "Pending One", authors: ["C D"], wizard: {bucket: "pending"})
            @adapter.expects(:create).never
            @adapter.expects(:recheck).never

            assert_equal 0, ImportRows.call(list: @list, adapter: @adapter)
          end
        end
      end
    end
  end
end
