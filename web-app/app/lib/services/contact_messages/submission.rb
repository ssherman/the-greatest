module Services
  module ContactMessages
    # Turns a submitted contact form into a ContactMessage plus an email to the
    # owner.
    #
    # The submitted email is used ONLY for an anonymous visitor. A signed-in
    # visitor's address is read from the user record, never from the form: the
    # footer is edge-cached and its form is filled in by the client, so the
    # posted value is not evidence of anything.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(email:, message:, domain:, user: nil, submitter_ip: nil)
        new(email: email, message: message, domain: domain,
          user: user, submitter_ip: submitter_ip).call
      end

      def initialize(email:, message:, domain:, user:, submitter_ip:)
        @email = email
        @message = message
        @domain = domain
        @user = user
        @submitter_ip = submitter_ip
      end

      def call
        # Root-anchored: a bare ContactMessage resolves against Services::
        # first, which has produced confusing NameErrors in this codebase.
        contact_message = ::ContactMessage.new(
          email: reply_address,
          message: @message,
          domain: @domain,
          user: @user,
          submitter_ip: @submitter_ip
        )

        if contact_message.save
          # deliver_later, not deliver_now: a mail outage must not block the
          # submitter, and Sidekiq retries. The row is already saved either way.
          AdminMailer.contact_message(contact_message).deliver_later
          Result.new(success?: true, data: contact_message, errors: [])
        else
          Result.new(success?: false, data: nil, errors: contact_message.errors.full_messages)
        end
      end

      private

      def reply_address = @user&.email.presence || @email
    end
  end
end
