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
class ContactMessage < ApplicationRecord
  # The same bound Correction puts on notes. Generous enough that no real
  # message is affected, while bounding an anonymous public write endpoint.
  MAX_MESSAGE_LENGTH = 10_000

  belongs_to :user, optional: true

  # Integers deliberately match NewsPost's mapping.
  enum :domain, {music: 0, games: 1, books: 2}

  # No `new` value: Rails generates a scope per enum value and
  # ContactMessage.new would collide with the constructor.
  enum :status, {pending: 0, replied: 1, spam: 2}

  # Required for anonymous submitters too, unlike legacy. A message with no
  # reply address cannot be answered, which is the entire point of the form.
  # The format check catches the honest typo, not a deliberate fake.
  #
  # URI::MailTo::EMAIL_REGEXP alone is not enough here: it accepts a domain with
  # no dot, so "shane@gmail" passes it -- the exact typo this validation exists
  # to catch. A dotless domain is legal in the RFC and useless for a public
  # contact form, whose reply has to route over public DNS.
  #
  # Deliberately looser on the LOCAL part than the URI regex. For a reply-to
  # address, wrongly rejecting a real address is the more expensive error, and
  # this is a typo check, not RFC compliance.
  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i

  validates :email, presence: true, format: {with: EMAIL_FORMAT}
  validates :message, presence: true, length: {maximum: MAX_MESSAGE_LENGTH}
end
