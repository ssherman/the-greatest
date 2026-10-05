require "test_helper"

# == Schema Information
#
# Table name: goodreads_imports
#
#  id         :bigint           not null, primary key
#  error      :text
#  status     :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_goodreads_imports_on_user_id  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module LegacyBooks
  class GoodreadsImportTest < ActiveSupport::TestCase
    # .allocate, not .new: .new introspects a table the test database lacks
    # (see goodreads_book_test.rb).
    test "reads the legacy goodreads_imports table, read-only" do
      assert_equal "goodreads_imports", GoodreadsImport.table_name
      assert_predicate GoodreadsImport.allocate, :readonly?
    end

    test "maps the legacy app's status integers" do
      assert_equal({0 => "not_started", 1 => "pending", 2 => "complete", 3 => "failed"}, GoodreadsImport::STATUSES)
    end

    test "finds its upload through the legacy attachment row" do
      reflection = GoodreadsImport.reflect_on_association(:file_attachment)

      assert_equal "LegacyBooks::ActiveStorageAttachment", reflection.class_name
      assert_equal "record_id", reflection.foreign_key
    end
  end
end
