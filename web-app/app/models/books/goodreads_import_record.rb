# == Schema Information
#
# Table name: books_goodreads_import_records
#
#  id          :bigint           not null, primary key
#  action      :integer          not null
#  record_type :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  import_id   :bigint           not null
#  record_id   :bigint           not null
#
# Indexes
#
#  index_books_goodreads_import_records_on_record   (record_type,record_id)
#  index_books_goodreads_import_records_uniqueness  (import_id,record_type,record_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (import_id => books_goodreads_imports.id) ON DELETE => cascade
#
module Books
  # Provenance: every book, author, book_author and identifier an import
  # created or stamped. Approval reads it to know what to promote, rejection
  # to know what to remove (Goodreads import spec §3, §10).
  class GoodreadsImportRecord < ApplicationRecord
    belongs_to :import, class_name: "Books::GoodreadsImport", inverse_of: :records
    belongs_to :record, polymorphic: true

    enum :action, {created: 0, stamped: 1}

    validates :record_id, uniqueness: {scope: [:import_id, :record_type]}
  end
end
