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
# What WorldCat and Open Library say about one Goodreads edition's ISBN
# (docs/features/goodreads-rebuild.md, "Survey pass 2"). Gathered on Shane's
# PC against local service instances and copied to production, so it is keyed
# by the edition's natural key (Goodreads id plus signature), which is the
# same in both databases, and has no foreign key: production may receive
# rows for editions a later weekly load has not brought it yet.
class Books::RebuildEditionEvidence < ApplicationRecord
  enum :world_cat, {no_isbn: 0, no_record: 1, agrees: 2, disagrees: 3, unclear: 4}

  validates :goodreads_book_id, :signature, :world_cat, :checked_at, presence: true

  # @return [Hash{Integer => Books::RebuildEditionEvidence}] by edition id, for those with evidence
  def self.for_editions(editions)
    return {} if editions.empty?

    by_key = editions.index_by { |edition| [edition.goodreads_book_id, edition.signature] }
    where(goodreads_book_id: editions.map(&:goodreads_book_id).uniq, signature: editions.map(&:signature).uniq)
      .each_with_object({}) do |evidence, found|
        edition = by_key[[evidence.goodreads_book_id, evidence.signature]]
        found[edition.id] = evidence if edition
      end
  end
end
