require "test_helper"

class ContactMessageTest < ActiveSupport::TestCase
  def valid_attributes
    {email: "reader@example.org", message: "Hello", domain: :books}
  end

  test "is valid with an email, a message and a domain" do
    assert_predicate ContactMessage.new(**valid_attributes), :valid?
  end

  test "requires an email" do
    record = ContactMessage.new(**valid_attributes, email: nil)

    assert_not_predicate record, :valid?
    assert_includes record.errors[:email], "can't be blank"
  end

  # Required for everyone, including anonymous submitters. Legacy accepted a
  # blank one and produced messages nobody could reply to.
  test "rejects a malformed email" do
    record = ContactMessage.new(**valid_attributes, email: "reader@example")

    assert_not_predicate record, :valid?
    assert_includes record.errors[:email], "is invalid"
  end

  test "requires a message" do
    record = ContactMessage.new(**valid_attributes, message: "")

    assert_not_predicate record, :valid?
    assert_includes record.errors[:message], "can't be blank"
  end

  test "rejects a message longer than the cap" do
    record = ContactMessage.new(**valid_attributes, message: "x" * (ContactMessage::MAX_MESSAGE_LENGTH + 1))

    assert_not_predicate record, :valid?
  end

  test "accepts a message exactly at the cap" do
    record = ContactMessage.new(**valid_attributes, message: "x" * ContactMessage::MAX_MESSAGE_LENGTH)

    assert_predicate record, :valid?
  end

  test "is anonymous without a user" do
    record = ContactMessage.new(**valid_attributes)

    assert_predicate record, :valid?
    assert_nil record.user
  end

  # The integers must match NewsPost's mapping, or the two models disagree
  # about what a stored 1 means.
  test "domain integers match NewsPost" do
    assert_equal NewsPost.domains.slice("music", "games", "books"), ContactMessage.domains
  end

  test "defaults to pending" do
    assert_predicate ContactMessage.new(**valid_attributes), :pending?
  end
end
