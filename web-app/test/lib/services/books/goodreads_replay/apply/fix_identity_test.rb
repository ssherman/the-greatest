require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class FixIdentityTest < ActiveSupport::TestCase
          AUTHOR_IMPORTER = ::DataImporters::Books::Author::Importer

          setup do
            @book = ::Books::Book.create!(id: GoodreadsRebuild::Cohort.post_import_range.first + 5_000, title: "Wrong Title")
            @wrong_author = ::Books::Author.create!(name: "Wrong Author")
            @book.book_authors.create!(author: @wrong_author, position: 1)
            @book.identifiers.create!(identifier_type: :books_work_asin, value: "B00LEGACY1", source: :legacy)
            @book.category_items.create!(category: categories(:books_fiction_genre))
            @author = ::Books::Author.create!(name: "Right Author")
            stub_author_import
          end

          def stub_author_import
            AUTHOR_IMPORTER.stubs(:call).returns(
              ::DataImporters::ImportResult.new(item: @author, provider_results: [], success: true, created: true)
            )
          end

          def verdict
            @verdict ||= ::Books::RepairVerdict.create!(kind: :fix_identity, subject_key: "rebuild:#{@book.id}", decided_by: :rule,
              status: :approved, payload: {"book_id" => @book.id, "title" => "Right Title", "subtitle" => "A Subtitle",
                                           "author_names" => ["Right Author"], "year" => 1999, "isbn13" => ["9781234567897"],
                                           "isbn10" => [], "goodreads_ids" => ["4242"], "ol_work_keys" => ["OL1W"]})
          end

          test "applies: export title, subtitle and year; old data gone; export author and identifiers with source goodreads_import" do
            result = FixIdentity.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            book = ::Books::Book.find(@book.id)
            assert_equal ["Right Title", "A Subtitle", 1999], [book.title, book.subtitle, book.first_published_year]
            assert_equal [@author], book.authors.to_a
            assert_equal 0, book.category_items.count
            refute book.identifiers.exists?(value: "B00LEGACY1")
            assert_equal "goodreads_import", book.identifiers.find_by!(identifier_type: :books_work_isbn13, value: "9781234567897").source
            assert_equal "goodreads_import", book.identifiers.find_by!(identifier_type: :books_work_goodreads_id, value: "4242").source
          end

          test "keeps the book's id, slug, user list items and reviews" do
            user = users(:regular_user)
            item = UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: @book, position: 1)
            review = Review.create!(user: user, reviewable: @book, rating: 4)
            slug = @book.slug

            FixIdentity.call(verdict: verdict)

            assert_equal [@book.id, slug], ::Books::Book.find(@book.id).then { |b| [b.id, b.slug] }
            assert UserListItem.exists?(item.id)
            assert Review.exists?(review.id)
          end

          test "writes ResetBook's archive and the created author ids onto the verdict" do
            FixIdentity.call(verdict: verdict)

            verdict.reload
            assert_includes verdict.payload["removed"]["identifiers"], ["books_work_asin", "B00LEGACY1", "legacy"]
            assert_equal [@author.id], verdict.payload["created_author_ids"]
          end

          test "never runs the Open Library provider or enrichment" do
            ::DataImporters::Books::Book::Providers::OpenLibrary.any_instance.expects(:populate).never
            ::Workflows::Books::BookEnrichment.expects(:start).never

            FixIdentity.call(verdict: verdict)
          end

          test "an author link ties the existing author to the book; the importer is given only the unlinked names" do
            existing = ::Books::Author.create!(name: "Daniel Dennett")
            verdict.update_columns(payload: verdict.payload.merge("author_names" => ["Daniel C. Dennett", "Right Author"],
              "author_links" => {"Daniel C. Dennett" => existing.id}))
            ::DataImporters::Books::Book::Importer.expects(:call).with { |args| args[:author_names] == ["Right Author"] && args[:providers] == %i[authors query_identifiers] }
              .returns(::DataImporters::ImportResult.new(item: @book, provider_results: [], success: true, created: false)).once

            assert_no_difference "::Books::Author.count" do
              FixIdentity.call(verdict: verdict)
            end

            assert_equal [existing], @book.reload.authors.to_a
            assert_equal ["Daniel C. Dennett"], existing.reload.alternate_names
          end

          test "a linked author listed first in the export stays ahead of the imported one" do
            existing = ::Books::Author.create!(name: "Linked Author")
            verdict.update_columns(payload: verdict.payload.merge("author_names" => ["Linked Author", "Right Author"],
              "author_links" => {"Linked Author" => existing.id}))

            FixIdentity.call(verdict: verdict)

            assert_equal [existing, @author], @book.reload.authors.to_a
          end

          test "an author whose alternate names already hold the export spelling in normalised form is not updated" do
            existing = ::Books::Author.create!(name: "Daniel Dennett", alternate_names: ["daniel c. dennett"])
            verdict.update_columns(payload: verdict.payload.merge("author_names" => ["Daniel C. Dennett"],
              "author_links" => {"Daniel C. Dennett" => existing.id}))
            stamp = existing.reload.updated_at

            FixIdentity.call(verdict: verdict)

            assert_equal stamp, existing.reload.updated_at
          end

          test "linked and imported authors take their places in the export's order" do
            existing = ::Books::Author.create!(name: "Second Author")
            verdict.update_columns(payload: verdict.payload.merge("author_names" => ["Right Author", "Second Author"],
              "author_links" => {"Second Author" => existing.id}))

            FixIdentity.call(verdict: verdict)

            assert_equal [@author, existing], @book.reload.authors.to_a
            assert_equal [1, 2], @book.book_authors.order(:position).pluck(:position)
          end

          test "when every author is linked the importer skips the authors provider" do
            existing = ::Books::Author.create!(name: "Right Author")
            verdict.update_columns(payload: verdict.payload.merge("author_links" => {"Right Author" => existing.id}))
            AUTHOR_IMPORTER.expects(:call).never

            FixIdentity.call(verdict: verdict)

            assert_equal [existing], @book.reload.authors.to_a
            assert_equal [], existing.alternate_names
          end

          test "a linked author that has vanished falls back to importing the name" do
            verdict.update_columns(payload: verdict.payload.merge("author_links" => {"Right Author" => 0}))

            FixIdentity.call(verdict: verdict)

            assert_equal [@author], @book.reload.authors.to_a
          end

          test "a never-applied apply stays idempotent for links" do
            existing = ::Books::Author.create!(name: "Right Author")
            verdict.update_columns(payload: verdict.payload.merge("author_links" => {"Right Author" => existing.id}))
            FixIdentity.call(verdict: verdict)
            verdict.update_columns(applied_at: nil)

            FixIdentity.call(verdict: verdict.reload)

            assert_equal [existing], @book.reload.authors.to_a
          end

          test "a second apply is a no-op and leaves data added since in place" do
            verdict
            ApplyVerdicts.call(auto_apply: true)
            @book.descriptions.create!(source: :manual, content: "added later")

            result = FixIdentity.call(verdict: verdict.reload)

            assert_equal :noop, result.data[:outcome]
            assert_equal 1, @book.descriptions.count
            assert_equal({"fix_identity noop" => 1}, ApplyVerdicts.call(auto_apply: true).data[:tally])
          end

          test "a book that became trusted is left alone" do
            ListItem.create!(list: lists(:books_list), listable: @book, position: 1)

            result = FixIdentity.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_equal "Wrong Title", @book.reload.title
            assert_equal 1, @book.book_authors.count
          end

          test "a book that is gone is a no-op" do
            verdict.update_columns(payload: verdict.payload.merge("book_id" => 0))

            assert_equal :noop, FixIdentity.call(verdict: verdict).data[:outcome]
          end

          test "an author import failure records the error, keeps the archive, and a retry applies" do
            verdict
            AUTHOR_IMPORTER.stubs(:call).raises(StandardError, "boom")

            tally = ApplyVerdicts.call(auto_apply: true).data[:tally]

            verdict.reload
            assert_equal({"fix_identity failed" => 1}, tally)
            assert_match(/author import failed/, verdict.error)
            assert_nil verdict.applied_at
            assert_equal "Right Title", @book.reload.title
            assert_includes verdict.payload["removed"]["identifiers"], ["books_work_asin", "B00LEGACY1", "legacy"]

            stub_author_import
            assert_equal({"fix_identity applied" => 1}, ApplyVerdicts.call(auto_apply: true).data[:tally])
            verdict.reload
            refute_nil verdict.applied_at
            assert_nil verdict.error
            assert_equal [@author], @book.reload.authors.to_a
          end

          test "a failure right after the reset rolls back the reset and the archive together" do
            verdict
            verdict.class.any_instance.stubs(:update_columns).raises(ActiveRecord::StatementInvalid, "boom")

            assert_raises(ActiveRecord::StatementInvalid) { FixIdentity.call(verdict: verdict) }

            assert @book.reload.identifiers.exists?(value: "B00LEGACY1")
            assert_equal 1, @book.book_authors.count
            refute verdict.reload.payload.key?("removed")
          end

          test "a retried apply keeps the first archive" do
            verdict
            AUTHOR_IMPORTER.stubs(:call).raises(StandardError, "boom")
            ApplyVerdicts.call(auto_apply: true)
            stub_author_import

            ApplyVerdicts.call(auto_apply: true)

            assert_includes verdict.reload.payload["removed"]["identifiers"], ["books_work_asin", "B00LEGACY1", "legacy"]
          end
        end
      end
    end
  end
end
