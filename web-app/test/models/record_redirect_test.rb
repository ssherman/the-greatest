require "test_helper"

class RecordRedirectTest < ActiveSupport::TestCase
  test "accepts a books book or author" do
    assert RecordRedirect.new(item_type: "Books::Book", from_id: 5, to_id: 9).valid?
    assert RecordRedirect.new(item_type: "Books::Author", from_id: 5, to_id: nil).valid?
  end

  test "rejects any other item type" do
    refute RecordRedirect.new(item_type: "Music::Album", from_id: 5).valid?
  end

  test "allows one row per item type and from id" do
    RecordRedirect.create!(item_type: "Books::Book", from_id: 5, to_id: 9)

    refute RecordRedirect.new(item_type: "Books::Book", from_id: 5, to_id: nil).valid?
    assert RecordRedirect.new(item_type: "Books::Author", from_id: 5).valid?
  end
end
