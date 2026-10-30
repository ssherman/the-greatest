# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class DecideFixTest < ActiveSupport::TestCase
        setup do
          @import = books_goodreads_imports(:regular_user_import)
          @row_number = 3_000
          @next_gr = 9_000
          @book = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_000, title: "Wrong Title")
          @finder = mock("finder")
        end

        def group_for(title:, world_cat: :no_record, ol_work_keys: [], volume: nil)
          @next_gr += 1
          edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: @next_gr, signature: "sig-#{@next_gr}", title: title,
            primary_author: "George Saunders", original_publication_year: 2013)
          ::Books::GoodreadsImportRow.create!(import: @import, row_number: (@row_number += 1), raw: {}, goodreads_edition: edition)
          ::Books::RebuildEditionEvidence.create!(goodreads_book_id: edition.goodreads_book_id, signature: edition.signature,
            world_cat: world_cat, ol_work_keys: ol_work_keys, checked_at: Time.current)
          {"edition_ids" => [edition.id], "goodreads_book_ids" => [edition.goodreads_book_id], "titles" => [title],
           "authors" => ["George Saunders"], "year" => 2013, "volume" => volume, "row_count" => 1}
        end

        def survey_for(book, group, classification: :coherent, title_agrees: false, authors_agree: false, wrong_book: true)
          ::Books::RebuildBookSurvey.create!(book: book, classification: classification, groups: [group], title_agrees: title_agrees,
            authors_agree: authors_agree, wrong_book: wrong_book, surveyed_at: Time.current)
        end

        def match(record, confidence: :high, decided_by: :rule)
          DataImporters::Match.new(outcome: :matched, record: record, confidence: confidence, decided_by: decided_by, reason: "same work")
        end

        def unmatched = DataImporters::Match.new(outcome: :unmatched, reason: "nothing found")

        def trusted_target(title: "Tenth of December", source: "open_library", key: "OL1W")
          target = ::Books::Book.create!(id: Cohort.post_import_range.first - 50, title: title)
          target.identifiers.create!(identifier_type: :books_work_openlibrary_id, value: key, source: source)
          target
        end

        def decide(survey, book: @book) = DecideFix.call(book: book, survey: survey, finder: @finder)

        test "records an automatic fix when nothing is found and WorldCat agrees" do
          survey = survey_for(@book, group_for(title: "Tenth of December", world_cat: :agrees))
          @finder.expects(:call).returns(unmatched)

          result = decide(survey)

          verdict = result.data[:verdict]
          assert_equal :fix, result.data[:outcome]
          assert_equal ["fix_identity", "approved", "high", "Tenth of December", "rebuild:#{@book.id}"],
            [verdict.kind, verdict.status, verdict.confidence, verdict.payload["title"], verdict.subject_key]
          assert_equal @book.id, verdict.payload["book_id"]
        end

        test "records a proposed fix when WorldCat does not agree" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(unmatched)

          verdict = decide(survey).data[:verdict]

          assert_equal ["proposed", "medium"], [verdict.status, verdict.confidence]
        end

        test "passes the facts query, verify and the book to the finder" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).with { |args| args[:verify] == true && args[:subject] == @book && args[:exclude] == @book && args[:query].title == "Tenth of December" }
            .returns(unmatched)

          decide(survey)
        end

        test "records an automatic merge into a trusted book that holds the group's verified Open Library work and the same title" do
          target = trusted_target
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target))

          result = decide(survey)

          verdict = result.data[:verdict]
          assert_equal :merge, result.data[:outcome]
          assert_equal ["merge_books", "approved", "certain", "rule"], [verdict.kind, verdict.status, verdict.confidence, verdict.decided_by]
          assert_equal [true, target.id, @book.id], [verdict.payload["reset_source"], verdict.payload["target_id"], verdict.payload["source_id"]]
        end

        test "proposes the merge when the target holds the work key only from a legacy source" do
          target = trusted_target(source: "legacy")
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target))

          verdict = decide(survey).data[:verdict]

          assert_equal ["merge_books", "proposed", target.id], [verdict.kind, verdict.status, verdict.payload["target_id"]]
        end

        test "proposes the merge when an admin already said these two are not the same book" do
          target = trusted_target
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]))
          a, b = [@book.id, target.id].minmax
          ::DuplicateCandidate.create!(item_type: "Books::Book", item_a_id: a, item_b_id: b, source: :human, status: :not_duplicate)
          @finder.expects(:call).returns(match(target))

          verdict = decide(survey).data[:verdict]

          assert_equal ["merge_books", "proposed"], [verdict.kind, verdict.status]
          assert_match(/not a duplicate/i, verdict.reason)
        end

        test "proposes the merge when the survey is a lump" do
          target = trusted_target
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]), classification: :lump)
          @finder.expects(:call).returns(match(target))

          assert_equal "proposed", decide(survey).data[:verdict].status
        end

        test "proposes the merge when the main group has a volume" do
          target = trusted_target
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"], volume: "2"))
          @finder.expects(:call).returns(match(target))

          assert_equal "proposed", decide(survey).data[:verdict].status
        end

        test "proposes the merge when the title does not agree exactly" do
          target = trusted_target(title: "Something Else")
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target))

          assert_equal "proposed", decide(survey).data[:verdict].status
        end

        test "proposes the merge when the target's verified Open Library work is a different work" do
          target = trusted_target(key: "OL2W")
          survey = survey_for(@book, group_for(title: "Tenth of December", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target))

          assert_equal ["merge_books", "proposed"], decide(survey).data[:verdict].then { |v| [v.kind, v.status] }
        end

        test "proposes the merge when the main group has no Open Library evidence" do
          target = trusted_target
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(match(target))

          assert_equal ["merge_books", "proposed"], decide(survey).data[:verdict].then { |v| [v.kind, v.status] }
        end

        test "auto-merges when the target's title plus subtitle equals the export title" do
          target = trusted_target(title: "Tenth")
          target.update!(subtitle: "of December")
          survey = survey_for(@book, group_for(title: "Tenth: of December", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target))

          assert_equal ["merge_books", "approved", "certain"], decide(survey).data[:verdict].then { |v| [v.kind, v.status, v.confidence] }
        end

        def volume_case(export:, target_title:, **opts)
          target = trusted_target(title: target_title)
          survey = survey_for(@book, group_for(title: export, ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target, **opts))
          decide(survey)
        end

        test "a volume mismatch refuses the merge" do
          result = volume_case(export: "Saga of the Swamp Thing: Book Five", target_title: "Saga Of The Swamp Thing, Book 1")

          assert_equal :fix, result.data[:outcome]
          assert_match(/merge refused.*volume or set/, result.data[:verdict].reason)
        end

        test "a set against a volume refuses the merge" do
          assert_equal :fix, volume_case(export: "Nausicaa of the Valley of the Wind: The Complete Series",
            target_title: "Nausicaa of the Valley of the Wind, Vol. 7").data[:outcome]
        end

        test "a numbered volume against the whole work refuses the merge" do
          assert_equal :fix, volume_case(export: "1Q84 Book 1", target_title: "1Q84").data[:outcome]
        end

        test "the same volume merges" do
          assert_equal :merge, volume_case(export: "Death Note, Vol. 1", target_title: "Death Note, Vol. 1").data[:outcome]
        end

        test "no volume on either side still merges across a translation" do
          result = volume_case(export: "Fundacion", target_title: "Foundation", decided_by: :ai, confidence: :medium)

          assert_equal [:merge, "proposed"], [result.data[:outcome], result.data[:verdict].status]
        end

        test "a title that only looks like a volume to a loose check still merges across a translation" do
          [
            ["Harry Potter and the Sorcerer's Stone (Harry Potter, #1)", "Harry Potter Y La Piedra Filosofal"],
            ["The Adventures of Tom Sawyer", "Las Aventuras De Tom Sawyer"],
            ["Fahrenheit 451", "Farenheit 451"],
            ["The Book Thief", "La Ladrona De Libros"],
            ["Band of Brothers", "Hermanos de Sangre"]
          ].each_with_index do |(export, target_title), index|
            book = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_100 + index, title: "Wrong #{index}")
            target = ::Books::Book.create!(id: Cohort.post_import_range.first - 100 - index, title: target_title)
            survey = survey_for(book, group_for(title: export))
            finder = mock("finder#{index}")
            finder.expects(:call).returns(match(target, decided_by: :ai, confidence: :medium))

            outcome = DecideFix.call(book: book, survey: survey, finder: finder).data[:outcome]

            assert_equal :merge, outcome, export
          end
        end

        test "the default finder is blinded on identifiers and alternate titles" do
          finder_class = ::DataImporters::Books::Book::Finder
          finder_class.expects(:new).with(
            open_library: :none,
            identifier_sources: finder_class::TRUSTED_IDENTIFIER_SOURCES,
            alternate_title_sources: finder_class::TRUSTED_ALTERNATE_TITLE_SOURCES
          ).returns(:finder)

          assert_equal :finder, DecideFix.default_finder
        end

        test "a failed finder run records nothing and asks for a retry" do
          survey = survey_for(@book, group_for(title: "Tenth of December", world_cat: :agrees))
          @finder.expects(:call).twice.returns(
            DataImporters::Match.new(outcome: :unmatched, decided_by: :fallback),
            DataImporters::Match.new(outcome: :unmatched, decided_by: :rule, sources_failed: [:opensearch])
          )

          2.times do
            result = decide(survey)
            assert_equal [:retry, nil], [result.data[:outcome], result.data[:verdict]]
          end
          assert_equal 0, ::Books::RepairVerdict.where(subject_key: "rebuild:#{@book.id}").count
        end

        test "a proposed merge keeps the match's confidence and an AI decision stays AI" do
          target = trusted_target(source: "legacy")
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(match(target, confidence: :medium, decided_by: :ai))

          verdict = decide(survey).data[:verdict]

          assert_equal ["ai", "medium"], [verdict.decided_by, verdict.confidence]
        end

        test "a match that is itself in the fix set gives a fix, not a merge" do
          other = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_001, title: "Also Wrong")
          survey_for(other, group_for(title: "Something"))
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(match(other))

          result = decide(survey)

          assert_equal [:fix, "fix_identity"], [result.data[:outcome], result.data[:verdict].kind]
        end

        test "a derived match whose title and authors agree is an eligible merge target" do
          other = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_001, title: "Tenth of December")
          survey_for(other, group_for(title: "Tenth of December"), title_agrees: true, authors_agree: true, wrong_book: false)
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(match(other))

          assert_equal :merge, decide(survey).data[:outcome]
        end

        test "a derived target with a translated title gets a fix, not a merge" do
          other = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_001, title: "Visul Numărul 9")
          survey_for(other, group_for(title: "Number9Dream"), title_agrees: true, authors_agree: true, wrong_book: false)
          survey = survey_for(@book, group_for(title: "Number9Dream"))
          @finder.expects(:call).returns(match(other, decided_by: :ai, confidence: :medium))

          result = decide(survey)

          assert_equal [:fix, "fix_identity"], [result.data[:outcome], result.data[:verdict].kind]
          assert_match(/different.*title/, result.data[:verdict].reason)
        end

        test "a derived target with the export's exact title still merges" do
          other = ::Books::Book.create!(id: Cohort.post_import_range.first + 7_001, title: "Of Test Mainframes")
          survey_for(other, group_for(title: "Of Test Mainframes"), title_agrees: true, authors_agree: true, wrong_book: false)
          survey = survey_for(@book, group_for(title: "Of Test Mainframes"))
          @finder.expects(:call).returns(match(other))

          assert_equal :merge, decide(survey).data[:outcome]
        end

        test "a trusted target with a different title can still be proposed" do
          target = trusted_target(title: "Foundation")
          survey = survey_for(@book, group_for(title: "Fundación", ol_work_keys: ["OL1W"]))
          @finder.expects(:call).returns(match(target, decided_by: :ai, confidence: :medium))

          result = decide(survey)

          assert_equal [:merge, "proposed"], [result.data[:outcome], result.data[:verdict].status]
        end

        test "a provisional match gives a fix" do
          target = trusted_target
          target.update!(provisional: true)
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(match(target))

          assert_equal :fix, decide(survey).data[:outcome]
        end

        test "an unmatched result gives a fix even with a record present" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).returns(DataImporters::Match.new(outcome: :unmatched, record: trusted_target))

          assert_equal :fix, decide(survey).data[:outcome]
        end

        test "a rejected merge gives a fix on the next run, without calling the finder" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "rebuild:#{@book.id}", decided_by: :rule, status: :rejected, payload: {})
          @finder.expects(:call).never

          assert_equal :fix, decide(survey).data[:outcome]
        end

        test "a trusted book is skipped" do
          trusted = ::Books::Book.create!(id: Cohort.post_import_range.first - 60, title: "Trusted")
          survey = survey_for(trusted, group_for(title: "Tenth of December"))
          @finder.expects(:call).never

          assert_equal :skipped, decide(survey, book: trusted).data[:outcome]
        end

        test "a book whose title and authors agree is skipped" do
          survey = survey_for(@book, group_for(title: "Tenth of December"), title_agrees: true, authors_agree: true, wrong_book: false)
          @finder.expects(:call).never

          assert_equal :skipped, decide(survey).data[:outcome]
          assert_equal 0, ::Books::RepairVerdict.where(subject_key: "rebuild:#{@book.id}").count
        end

        test "an unsupported book is skipped" do
          survey = survey_for(@book, group_for(title: "Tenth of December"), classification: :unsupported)

          assert_equal :skipped, decide(survey).data[:outcome]
        end

        test "a wrong book is not skipped even when title and authors agree" do
          survey = survey_for(@book, group_for(title: "Tenth of December"), title_agrees: true, authors_agree: true, wrong_book: true)
          @finder.expects(:call).returns(unmatched)

          assert_equal :fix, decide(survey).data[:outcome]
        end

        test "a second run keeps an existing proposed fix" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          @finder.expects(:call).once.returns(unmatched)
          first = decide(survey).data[:verdict]

          again = decide(survey)

          assert_equal [:kept, first.id], [again.data[:outcome], again.data[:verdict].id]
          assert_equal 1, ::Books::RepairVerdict.where(subject_key: "rebuild:#{@book.id}").count
        end

        test "an existing proposed or approved merge is kept" do
          survey = survey_for(@book, group_for(title: "Tenth of December"))
          existing = ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "rebuild:#{@book.id}", decided_by: :rule, payload: {})
          @finder.expects(:call).never

          result = decide(survey)

          assert_equal [:kept, existing.id], [result.data[:outcome], result.data[:verdict].id]
        end

        test "needs_fix? is a pure function of the survey row" do
          build = ->(**a) { ::Books::RebuildBookSurvey.new({classification: :coherent, groups: [{"titles" => []}], title_agrees: false, authors_agree: false, wrong_book: false}.merge(a)) }

          assert DecideFix.needs_fix?(build.call)
          assert DecideFix.needs_fix?(build.call(classification: :lump, title_agrees: true, authors_agree: true, wrong_book: true))
          assert DecideFix.needs_fix?(build.call(title_agrees: true, authors_agree: false))
          refute DecideFix.needs_fix?(build.call(title_agrees: true, authors_agree: true))
          refute DecideFix.needs_fix?(build.call(classification: :unsupported))
        end
      end
    end
  end
end
