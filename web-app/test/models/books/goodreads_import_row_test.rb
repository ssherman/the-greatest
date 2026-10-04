require "test_helper"

# == Schema Information
#
# Table name: books_goodreads_import_rows
#
#  id                   :bigint           not null, primary key
#  applied              :jsonb            not null
#  date_added           :date
#  date_read            :date
#  error                :text
#  exclusive_shelf      :string
#  notes                :string           default([]), not null, is an Array
#  outcome              :integer          default(0), not null
#  outcome_detail       :string
#  rating               :integer
#  raw                  :jsonb            not null
#  read_count           :integer
#  review_body          :text
#  row_number           :integer          not null
#  shelf_positions      :jsonb            not null
#  shelves              :string           default([]), not null, is an Array
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  goodreads_edition_id :bigint
#  import_id            :bigint           not null
#
# Indexes
#
#  index_books_goodreads_import_rows_on_goodreads_edition_id      (goodreads_edition_id)
#  index_books_goodreads_import_rows_on_import_id_and_row_number  (import_id,row_number) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (goodreads_edition_id => books_goodreads_editions.id)
#  fk_rails_...  (import_id => books_goodreads_imports.id) ON DELETE => cascade
#
module Books
  class GoodreadsImportRowTest < ActiveSupport::TestCase
    test "a rating is 0 to 5 or absent" do
      row = books_goodreads_import_rows(:war_and_peace_row)

      assert row.tap { |r| r.rating = 0 }.valid?
      assert row.tap { |r| r.rating = nil }.valid?
      assert_not row.tap { |r| r.rating = 6 }.valid?
    end

    test "a row number is used once per import" do
      existing = books_goodreads_import_rows(:war_and_peace_row)

      assert_not GoodreadsImportRow.new(import: existing.import, row_number: existing.row_number).valid?
    end
  end
end
