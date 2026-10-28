require "test_helper"

# == Schema Information
#
# Table name: books_rebuild_edition_evidences
#
#  id                :bigint           not null, primary key
#  checked_at        :datetime         not null
#  isbn13            :string
#  ol_work_keys      :string           default([]), not null, is an Array
#  signature         :string           not null
#  world_cat         :integer          not null
#  world_cat_creator :string
#  world_cat_title   :string
#  world_cat_year    :integer
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  goodreads_book_id :bigint           not null
#
# Indexes
#
#  index_books_rebuild_edition_evidences_on_natural_key  (goodreads_book_id,signature) UNIQUE
#
module Books
  class RebuildEditionEvidenceTest < ActiveSupport::TestCase
    test "the natural key is unique" do
      existing = books_rebuild_edition_evidences(:war_and_peace_evidence)
      dup = RebuildEditionEvidence.new(goodreads_book_id: existing.goodreads_book_id, signature: existing.signature,
        world_cat: :no_record, checked_at: Time.current)

      assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
    end

    test "world_cat enum" do
      assert_equal %w[no_isbn no_record agrees disagrees unclear], RebuildEditionEvidence.world_cats.keys
    end

    test "for_editions matches on goodreads id and signature" do
      with = books_goodreads_editions(:war_and_peace_edition)
      without = books_goodreads_editions(:unresolved_edition)

      found = RebuildEditionEvidence.for_editions([with, without])

      assert_equal [with.id], found.keys
      assert_equal books_rebuild_edition_evidences(:war_and_peace_evidence), found[with.id]
    end

    test "for_editions with none" do
      assert_equal({}, RebuildEditionEvidence.for_editions([]))
    end
  end
end
