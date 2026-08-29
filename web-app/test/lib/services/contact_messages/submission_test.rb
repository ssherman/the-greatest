require "test_helper"

module Services
  module ContactMessages
    class SubmissionTest < ActiveSupport::TestCase
      test "stores an anonymous submission" do
        result = Submission.call(
          email: "reader@example.org", message: "Hello", domain: :books, submitter_ip: "203.0.113.5"
        )

        assert_predicate result, :success?
        assert_equal "reader@example.org", result.data.email
        assert_equal "203.0.113.5", result.data.submitter_ip
        assert_nil result.data.user
        assert_predicate result.data, :books?
      end

      # The submitted email is IGNORED for a signed-in visitor. The prefill is a
      # convenience; the server decides who the message is from.
      test "uses the signed-in user's email and ignores the submitted one" do
        user = users(:regular_user)

        result = Submission.call(
          email: "attacker@example.org", message: "Hello", user: user, domain: :books
        )

        assert_predicate result, :success?
        assert_equal user.email, result.data.email
        assert_equal user, result.data.user
      end

      test "fails with errors when the message is blank" do
        result = Submission.call(email: "reader@example.org", message: "", domain: :books)

        assert_not_predicate result, :success?
        assert_nil result.data
        assert_not_empty result.errors
      end

      test "fails when an anonymous email is malformed" do
        result = Submission.call(email: "nope", message: "Hello", domain: :books)

        assert_not_predicate result, :success?
        assert_not_empty result.errors
      end

      test "persists nothing on failure" do
        assert_no_difference "ContactMessage.count" do
          Submission.call(email: "reader@example.org", message: "", domain: :books)
        end
      end

      test "enqueues the admin email on success" do
        AdminMailer.expects(:contact_message).returns(stub(deliver_later: true))

        Submission.call(email: "reader@example.org", message: "Hello", domain: :books)
      end

      test "sends no email on failure" do
        AdminMailer.expects(:contact_message).never

        Submission.call(email: "reader@example.org", message: "", domain: :books)
      end
    end
  end
end
