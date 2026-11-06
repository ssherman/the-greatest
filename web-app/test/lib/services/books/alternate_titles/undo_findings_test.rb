# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module AlternateTitles
      class UndoFindingsTest < ActiveSupport::TestCase
        REMOVED = "The Treasure of the City of Ladies"
        WORK_KEY = "OL1W"

        setup do
          @book = books_books(:war_and_peace)
          @verification = ::Books::Verification.create!(book: @book, work_outcome: :keyed, run_id: "r", new_key: WORK_KEY)
          @removed = add_title(REMOVED, :removed)
          @client = mock
          stub_work("War and Peace")
        end

        def add_title(title, status)
          removed = status == :removed
          AlternateTitle.create!(titleable: @book, title: title, source: :legacy, status: status,
            verdict: removed ? :not_same_work : :same_work, category: removed ? :junk : nil, decided_by: :ai)
        end

        def stub_work(title)
          work = ::Books::OpenLibrary::Work.new(key: WORK_KEY, source: "ol", title: title, subtitle: nil, description: nil,
            author_keys: [], author_names: [], subjects: [], year_evidence: nil, popularity: nil, redirected_from: [], source_version: nil)
          @client.stubs(:works_batch).returns({WORK_KEY => work})
        end

        # An identifier the pass wrote (held under `held`, default the finding's source) and its finding.
        def added(value, title, kind: :added, source: :open_library, held: nil, **attributes)
          identifier = @book.identifiers.create!(identifier_type: :books_work_isbn13, value: value, source: held || source)
          @verification.findings.create!(book: @book, kind: kind, identifier_type: :books_work_isbn13, value: value,
            identifier_id: identifier.id, source: source, evidence: {"edition_key" => "OL9M", "title" => title}, **attributes)
          identifier
        end

        def run_undo(apply: true) = UndoFindings.call(apply: apply, client: @client)

        def finding(value, kind = :added) = @verification.findings.find_by!(value: value, kind: kind)

        test "finding agreeing only through a removed title is undone" do
          identifier = added("9780000000001", REMOVED)

          result = run_undo

          assert result.success?
          refute ::Identifier.exists?(identifier.id)
          assert_predicate finding("9780000000001"), :undo_identifier_destroyed?
          assert_not_nil finding("9780000000001").undone_at
          assert_equal 1, result.data[:undone][:identifier_destroyed]
          assert_equal 1, result.data[:findings_checked]
          assert_predicate result.data[:samples], :any?
        end

        test "finding agreeing through a kept title too stays" do
          identifier = added("9780000000002", "War and Peace")

          run_undo

          assert ::Identifier.exists?(identifier.id)
          assert_nil finding("9780000000002").undone_at
        end

        test "review titles still agree" do
          add_title("Voyna i Mir Review", :review)
          identifier = added("9780000000003", "Voyna i Mir Review")

          run_undo

          assert ::Identifier.exists?(identifier.id)
          assert_nil finding("9780000000003").undone_at
        end

        test "confirmed finding goes back to its previous source" do
          identifier = added("9780000000004", REMOVED, kind: :confirmed, previous_source: :legacy)

          run_undo

          assert_predicate identifier.reload, :source_legacy?
          assert_predicate finding("9780000000004", :confirmed), :undo_source_restored?
        end

        test "added then worldcat confirmed identifier is destroyed" do
          identifier = added("9780000000005", REMOVED, held: :worldcat)
          @verification.findings.create!(book: @book, kind: :confirmed, identifier_type: :books_work_isbn13, value: "9780000000005",
            identifier_id: identifier.id, source: :worldcat, previous_source: :open_library,
            evidence: {"records" => [{"oclc" => "1", "title" => REMOVED, "creator" => "x", "year" => 1900}]})

          run_undo

          refute ::Identifier.exists?(identifier.id)
          assert_equal 2, @verification.findings.where(value: "9780000000005").where.not(undone_at: nil).count
        end

        test "identifier held with another source is left" do
          identifier = added("9780000000006", REMOVED, held: :worldcat)
          @verification.findings.create!(book: @book, kind: :confirmed, identifier_type: :books_work_isbn13, value: "9780000000006",
            identifier_id: identifier.id, source: :worldcat, previous_source: :open_library,
            evidence: {"records" => [{"oclc" => "1", "title" => "War and Peace", "creator" => "x", "year" => 1900}]})

          run_undo

          assert ::Identifier.exists?(identifier.id)
          assert_predicate identifier.reload, :source_worldcat?
          assert_nil finding("9780000000006").undone_at
          assert_nil finding("9780000000006").undo_action
        end

        test "a finding left alone is judged again once the confirmation behind it is undone" do
          kept = add_title("Kept Title", :kept)
          identifier = added("9780000000020", REMOVED, held: :worldcat)
          @verification.findings.create!(book: @book, kind: :confirmed, identifier_type: :books_work_isbn13, value: "9780000000020",
            identifier_id: identifier.id, source: :worldcat, previous_source: :open_library,
            evidence: {"records" => [{"oclc" => "1", "title" => "Kept Title", "creator" => "x", "year" => 1900}]})

          first = run_undo
          assert ::Identifier.exists?(identifier.id)
          assert_equal 0, first.data[:undone].values.sum
          assert_equal 1, first.data[:left_alone]

          kept.update!(status: :removed, verdict: :not_same_work, category: :junk)
          second = run_undo

          refute ::Identifier.exists?(identifier.id)
          assert_equal 1, second.data[:undone][:source_restored]
          assert_equal 1, second.data[:undone][:identifier_destroyed]
        end

        test "dry run counts match apply for a confirmed then added pair" do
          identifier = added("9780000000021", REMOVED, held: :worldcat)
          @verification.findings.create!(book: @book, kind: :confirmed, identifier_type: :books_work_isbn13, value: "9780000000021",
            identifier_id: identifier.id, source: :worldcat, previous_source: :open_library,
            evidence: {"records" => [{"oclc" => "1", "title" => REMOVED, "creator" => "x", "year" => 1900}]})

          dry = run_undo(apply: false)
          applied = run_undo

          assert_equal dry.data[:undone], applied.data[:undone]
          assert_equal 1, applied.data[:undone][:source_restored]
          assert_equal 1, applied.data[:undone][:identifier_destroyed]
        end

        test "only the removed rows that were judged are stamped" do
          late = nil
          ::Services::Books::Verification::Check.stubs(:titles_agree?).with do |*|
            late ||= add_title("Removed Mid Run", :removed)
            true
          end.returns(false)

          run_undo

          assert_not_nil @removed.reload.undo_checked_at
          assert_nil late.reload.undo_checked_at
        end

        test "redo reverses a chained pair" do
          identifier = added("9780000000022", REMOVED, held: :worldcat)
          @verification.findings.create!(book: @book, kind: :confirmed, identifier_type: :books_work_isbn13, value: "9780000000022",
            identifier_id: identifier.id, source: :worldcat, previous_source: :open_library,
            evidence: {"records" => [{"oclc" => "1", "title" => REMOVED, "creator" => "x", "year" => 1900}]})
          run_undo

          assert UndoFindings.redo(finding: finding("9780000000022")).success?
          assert UndoFindings.redo(finding: finding("9780000000022", :confirmed)).success?

          restored = @book.identifiers.find_by!(value: "9780000000022")
          assert_predicate restored, :source_worldcat?
          assert_equal [[nil, nil]] * 2, @verification.findings.where(value: "9780000000022").map { |f| [f.undone_at, f.undo_action] }
          assert_equal [restored.id], @verification.findings.where(value: "9780000000022").map(&:identifier_id).uniq
        end

        test "wrong work is listed and its title does not count" do
          stub_work(REMOVED)
          key = @book.identifiers.create!(identifier_type: :books_work_openlibrary_id, value: WORK_KEY, source: :open_library)
          identifier = added("9780000000007", REMOVED)

          result = run_undo

          refute ::Identifier.exists?(identifier.id)
          assert ::Identifier.exists?(key.id)
          assert_equal [{book_id: @book.id, title: "War and Peace", work_key: WORK_KEY, work_title: REMOVED}], result.data[:wrong_work]
        end

        test "an edition matching only the wrong work's title is undone" do
          add_title("Some Other Book", :removed)
          stub_work("Some Other Book")
          identifier = added("9780000000008", "Some Other Book")

          result = run_undo

          refute ::Identifier.exists?(identifier.id)
          assert_equal 1, result.data[:wrong_work].size
        end

        test "dry run writes nothing" do
          identifier = added("9780000000009", REMOVED)

          result = run_undo(apply: false)

          assert_equal 1, result.data[:undone][:identifier_destroyed]
          assert ::Identifier.exists?(identifier.id)
          assert_nil finding("9780000000009").undone_at
          assert_nil @removed.reload.undo_checked_at
        end

        test "apply is idempotent" do
          added("9780000000010", REMOVED)
          run_undo

          result = run_undo

          assert_equal 0, result.data[:books]
          assert_equal 0, result.data[:undone].values.sum
          assert_not_nil @removed.reload.undo_checked_at
        end

        test "a later removal is processed on the next run" do
          run_undo
          later = add_title("Another Junk Title", :removed)
          identifier = added("9780000000011", "Another Junk Title")

          result = run_undo

          assert_equal 1, result.data[:books]
          refute ::Identifier.exists?(identifier.id)
          assert_not_nil later.reload.undo_checked_at
        end

        test "a book without a verification row is only marked" do
          row = AlternateTitle.where(titleable: books_books(:crime_and_punishment), status: :removed).first

          run_undo

          assert_not_nil row.reload.undo_checked_at
        end

        test "redo recreates the identifier" do
          identifier = added("9780000000012", REMOVED)
          run_undo
          undone = finding("9780000000012")

          result = UndoFindings.redo(finding: undone)

          assert result.success?
          restored = @book.identifiers.find_by!(value: "9780000000012")
          assert_predicate restored, :source_open_library?
          assert_equal restored.id, undone.reload.identifier_id
          assert_nil undone.undone_at
          assert_nil undone.undo_action
          refute_equal identifier.id, restored.id
        end

        test "redo refuses when another book holds the value verified" do
          added("9780000000013", REMOVED)
          run_undo
          ::Identifier.create!(identifiable: books_books(:crime_and_punishment), identifier_type: :books_work_isbn13,
            value: "9780000000013", source: :worldcat)

          result = UndoFindings.redo(finding: finding("9780000000013"))

          refute result.success?
          assert_not_nil finding("9780000000013").undone_at
        end

        test "redo sets a restored source back" do
          identifier = added("9780000000014", REMOVED, kind: :confirmed, previous_source: :legacy)
          run_undo

          assert UndoFindings.redo(finding: finding("9780000000014", :confirmed)).success?
          assert_predicate identifier.reload, :source_open_library?
        end

        test "a work key open library does not return counts as no work" do
          @client.stubs(:works_batch).returns({})
          identifier = added("9780000000015", REMOVED)

          result = run_undo

          refute ::Identifier.exists?(identifier.id)
          assert_empty result.data[:wrong_work]
          assert(result.data[:samples].any? { |sample| sample.include?("work not found") })
        end
      end
    end
  end
end
