require "test_helper"

module Services
  module Books
    module Authors
      class AdminCreateTest < ActiveSupport::TestCase
        QID = "Q1234567"

        setup { ::Workflows::Books::AuthorEnrichment.stubs(:start) }

        test "creates an author" do
          result = AdminCreate.call(attrs: {"name" => "Brand New Writer", "birth_year" => 1950})

          assert result.success?
          author = result.data[:author]
          assert author.persisted?
          assert_equal ["Brand New Writer", 1950], [author.name, author.birth_year]
        end

        test "alternate names are normalised" do
          result = AdminCreate.call(attrs: {"name" => "Alt Writer", "alternate_names" => ["  Alt One ", "", "Alt One", "Alt Two"]})

          assert_equal ["Alt One", "Alt Two"], result.data[:author].alternate_names
        end

        test "stores a qid as an admin identifier and starts the enrichment" do
          ::Workflows::Books::AuthorEnrichment.expects(:start).once

          result = AdminCreate.call(attrs: {"name" => "Qid Writer"}, wikidata_qid: "q1234567")

          assert result.success?
          row = result.data[:author].identifiers.find_by!(identifier_type: :books_author_wikidata_qid)
          assert_equal [QID, "admin"], [row.value, row.source]
        end

        test "create refuses a qid another author holds" do
          holder = books_authors(:tolstoy)
          holder.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: QID, source: :admin)

          result = nil
          assert_no_difference("::Books::Author.count") do
            result = AdminCreate.call(attrs: {"name" => "Another Tolstoy"}, wikidata_qid: QID)
          end

          assert_not result.success?
          assert_equal :conflict, result.code
          assert_equal holder, result.data[:holder]
        end

        test "create refuses a qid a provisional author holds" do
          holder = books_authors(:king)
          holder.update!(provisional: true)
          holder.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: QID, source: :admin)

          result = nil
          assert_no_difference("::Books::Author.count") do
            result = AdminCreate.call(attrs: {"name" => "Another King"}, wikidata_qid: QID)
          end

          assert_equal [:conflict, holder], [result.code, result.data[:holder]]
        end

        test "the id is locked before the holder check and a holder that appears under the lock is refused" do
          rival = books_authors(:king)
          AdminCreate.expects(:lock_qid).with(QID).once.with do
            rival.identifiers.create!(identifier_type: :books_author_wikidata_qid, value: QID, source: :admin)
          end

          result = nil
          assert_no_difference("::Books::Author.count") do
            result = AdminCreate.call(attrs: {"name" => "Late Twin"}, wikidata_qid: QID)
          end

          assert_equal [:conflict, rival], [result.code, result.data[:holder]]
        end

        test "no lock is taken without a qid" do
          AdminCreate.expects(:lock_qid).never

          assert AdminCreate.call(attrs: {"name" => "No Qid"}).success?
        end

        test "an unknown kind is unprocessable" do
          result = AdminCreate.call(attrs: {"name" => "Odd", "kind" => "bogus"})

          assert_equal :unprocessable, result.code
        end

        test "a blank name is unprocessable" do
          result = nil
          assert_no_difference("::Books::Author.count") do
            result = AdminCreate.call(attrs: {"name" => "  "})
          end

          assert_not result.success?
          assert_equal :unprocessable, result.code
          assert result.errors.any?
        end

        test "a refused identifier write creates nothing" do
          ::Services::Books::Identifiers::AdminWrite.stubs(:add).returns(
            ::Services::Books::Identifiers::AdminWrite::Result.new(success?: false, data: {code: :invalid}, errors: ["nope"])
          )

          result = nil
          assert_no_difference("::Books::Author.count") do
            result = AdminCreate.call(attrs: {"name" => "Rolled Back"}, wikidata_qid: QID)
          end

          assert_equal [:unprocessable, ["nope"]], [result.code, result.errors]
        end
      end
    end
  end
end
