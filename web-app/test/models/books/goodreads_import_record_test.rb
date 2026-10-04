require "test_helper"

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
  class GoodreadsImportRecordTest < ActiveSupport::TestCase
    test "a record is recorded once per import" do
      import = books_goodreads_imports(:regular_user_import)
      import.records.create!(record: books_books(:war_and_peace), action: :created)

      assert_not import.records.new(record: books_books(:war_and_peace), action: :stamped).valid?
    end
  end
end
