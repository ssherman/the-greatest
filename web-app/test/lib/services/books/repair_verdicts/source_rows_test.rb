# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module RepairVerdicts
      class SourceRowsTest < ActiveSupport::TestCase
        setup do
          @import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, legacy_import_id: 4242)
          (1..25).each do |number|
            @import.rows.create!(row_number: number, raw: {"Title" => "Title #{number}", "Author" => "Author #{number}"})
          end
        end

        def verdict(key, kind:, payload:)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, decided_by: :rule, confidence: :certain,
            payload: payload, reason: "test")
        end

        test "a reimport_row verdict resolves its own import id and row number" do
          v = verdict("reimport:row:#{@import.id}:3", kind: :reimport_row, payload: {"import_id" => @import.id, "row_number" => 3})

          assert_equal [[@import.id, 3]], SourceRows.pairs(v)
          assert_equal [@import.rows.find_by(row_number: 3)], SourceRows.call(v)
        end

        test "a reimport_row verdict without its import id or row number has no rows" do
          [{"row_number" => 3}, {"import_id" => @import.id}].each_with_index do |payload, index|
            v = verdict("t:bare:#{index}", kind: :reimport_row, payload: payload)

            assert_equal [], SourceRows.pairs(v)
            assert_equal [], SourceRows.call(v)
          end
        end

        test "a reimport_mixed verdict resolves its row_keys, capped by limit, dropping keys that name no row" do
          keys = (1..25).map { |number| [@import.id, number] } + [[@import.id, 999]]
          v = verdict("t:mixed", kind: :reimport_mixed, payload: {"row_keys" => keys})

          assert_equal 26, SourceRows.pairs(v).size
          assert_equal (1..20).to_a, SourceRows.call(v, limit: 20).map(&:row_number)
          assert_equal (1..25).to_a, SourceRows.call(v).map(&:row_number)
        end

        test "re-import keys are our import ids, never legacy ids" do
          decoy = ::Books::GoodreadsImport.create!(user: users(:admin_user), source: :legacy_replay, legacy_import_id: @import.id + 1_000_000)
          decoy.rows.create!(row_number: 1, raw: {"Title" => "Decoy"})
          v = verdict("t:ours", kind: :reimport_row, payload: {"import_id" => decoy.legacy_import_id, "row_number" => 1})

          assert_equal [], SourceRows.call(v)
        end

        test "a verdict with legacy rows pairs still resolves them through legacy_import_id" do
          v = verdict("t:legacy", kind: :fix_identity, payload: {"rows" => [[4242, 2]]})

          assert_equal [@import.rows.find_by(row_number: 2)], SourceRows.call(v)
        end
      end
    end
  end
end
