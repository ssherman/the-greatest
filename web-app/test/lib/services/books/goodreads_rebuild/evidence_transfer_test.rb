# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class EvidenceTransferTest < ActiveSupport::TestCase
        setup do
          @path = Rails.root.join("tmp", "evidence_transfer_test_#{SecureRandom.hex(4)}.jsonl.gz").to_s
          @other = ::Books::RebuildEditionEvidence.create!(goodreads_book_id: 77, signature: "sig-77", isbn13: "9780679731726",
            world_cat: :disagrees, world_cat_title: "Cooking for one /", ol_work_keys: %w[OL1W OL2W], checked_at: 2.days.ago)
        end

        teardown { FileUtils.rm_f(@path) }

        def comparable(evidence) = evidence.attributes.except("id", "created_at", "updated_at").merge("checked_at" => evidence.checked_at.to_i)

        test "export then import round-trips" do
          before = ::Books::RebuildEditionEvidence.order(:goodreads_book_id).map { |evidence| comparable(evidence) }

          assert_equal before.size, EvidenceTransfer.export(@path)
          ::Books::RebuildEditionEvidence.delete_all
          EvidenceTransfer.import(@path)

          assert_equal before, ::Books::RebuildEditionEvidence.order(:goodreads_book_id).map { |evidence| comparable(evidence) }
        end

        test "import updates an existing row" do
          EvidenceTransfer.export(@path)
          @other.update!(world_cat: :no_record, ol_work_keys: [])

          EvidenceTransfer.import(@path)

          assert_predicate @other.reload, :disagrees?
          assert_equal %w[OL1W OL2W], @other.ol_work_keys
          assert_equal 1, ::Books::RebuildEditionEvidence.where(goodreads_book_id: 77).count
        end

        test "import counts rows for editions this database lacks" do
          EvidenceTransfer.export(@path)

          counts = EvidenceTransfer.import(@path)

          # The war_and_peace fixture's edition exists here; goodreads 77 has none.
          assert_equal({"imported" => 2, "no_edition_here" => 1}, counts)
        end
      end
    end
  end
end
