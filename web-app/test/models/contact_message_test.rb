require "test_helper"

# == Schema Information
#
# Table name: contact_messages
#
#  id           :bigint           not null, primary key
#  domain       :integer          not null
#  email        :string           not null
#  message      :text             not null
#  replied_at   :datetime
#  status       :integer          default(0), not null
#  submitter_ip :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#
# Indexes
#
#  index_contact_messages_on_domain_and_created_at  (domain,created_at)
#  index_contact_messages_on_status_and_created_at  (status,created_at)
#  index_contact_messages_on_user_id                (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
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
