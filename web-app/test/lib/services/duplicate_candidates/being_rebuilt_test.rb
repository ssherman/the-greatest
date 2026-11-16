# frozen_string_literal: true

require "test_helper"

module Services
  module DuplicateCandidates
    class BeingRebuiltTest < ActiveSupport::TestCase
      setup do
        @mixed = ::Books::Book.create!(title: "Mixed")
        @other = ::Books::Book.create!(title: "Other")
        @third = ::Books::Book.create!(title: "Third")
        @verdict = mixed_verdict(@mixed)
        @with_mixed = pair(@mixed, @other)
        @plain = pair(@other, @third)
      end

      def mixed_verdict(book, status: :approved, **attrs)
        payload = {"book_id" => book.id}.merge(attrs.delete(:payload) || {})
        ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:mixed:#{book.id}", payload: payload,
          decided_by: :rule, status: status, **attrs)
      end

      def pair(a, b, type: "Books::Book", **attrs)
        ids = [a.id, b.id].minmax
        ::DuplicateCandidate.create!({item_type: type, item_a_id: ids[0], item_b_id: ids[1], source: :ai}.merge(attrs))
      end

      def pending_scope = ::DuplicateCandidate.where(id: [@with_mixed.id, @plain.id])

      test "a pair naming a book the re-import is emptying is hidden, and only it" do
        assert_equal [@plain.id], BeingRebuilt.exclude(pending_scope).pluck(:id)
        assert_equal [@with_mixed.id], BeingRebuilt.only(pending_scope).pluck(:id)
      end

      test "a kept, applied, superseded or unapproved mixed verdict does not hide the pair" do
        [{payload: {"kept" => true}}, {applied_at: Time.current}, {superseded_at: Time.current}, {status: :proposed}].each do |attrs|
          @verdict.destroy!
          @verdict = mixed_verdict(@mixed, **attrs)

          assert_equal [@plain.id, @with_mixed.id].sort, BeingRebuilt.exclude(pending_scope).pluck(:id).sort, attrs.inspect
        end
      end

      test "only book pairs are affected: an author pair sharing the id is not hidden" do
        author = ::Books::Author.create!(name: "A")
        other = ::Books::Author.create!(name: "B")
        author.update_columns(id: @mixed.id) unless ::Books::Author.exists?(@mixed.id)
        author_pair = ::DuplicateCandidate.create!(item_type: "Books::Author", item_a_id: [@mixed.id, other.id].min,
          item_b_id: [@mixed.id, other.id].max, source: :ai)

        assert_includes BeingRebuilt.exclude(::DuplicateCandidate.where(id: author_pair.id)).pluck(:id), author_pair.id
      end

      test "book_ids answers which of the given books are being rebuilt" do
        assert_equal Set[@mixed.id], BeingRebuilt.book_ids([@mixed.id, @other.id, @third.id])
        assert_equal Set.new, BeingRebuilt.book_ids([])
      end

      test "close_pairs_for marks the deleted book's pending pairs not duplicates with the reason, and leaves resolved ones" do
        merged = pair(@mixed, @third, status: :merged, resolved_at: 1.day.ago)

        freeze_time do
          assert_equal 1, BeingRebuilt.close_pairs_for(@mixed.id)

          @with_mixed.reload
          assert @with_mixed.not_duplicate?
          assert_equal [Time.current, BeingRebuilt::CLOSED_NOTE], [@with_mixed.resolved_at, @with_mixed.resolution_note]
        end
        assert merged.reload.merged?
        assert @plain.reload.pending?
      end
    end
  end
end
