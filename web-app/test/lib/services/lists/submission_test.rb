require "test_helper"

module Services
  module Lists
    class SubmissionTest < ActiveSupport::TestCase
      setup do
        @user = users(:regular_user)
        @attributes = {name: "Greatest Books Ever", source: "The Times",
                       url: "https://example.com/greatest", description: "A list."}
      end

      test "creates an unapproved list stamped as a submission" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: @user, submitter_email: nil, submitter_ip: "203.0.113.7")

        assert result.success?
        list = result.data
        assert_equal "Greatest Books Ever", list.name
        assert_equal "Books::List", list.type
        assert list.unapproved?
        assert_not_nil list.submitted_at
        assert_equal @user, list.submitted_by
        assert_equal "203.0.113.7", list.submitter_ip
      end

      test "accepts an anonymous submission with an email" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: "reader@example.com", submitter_ip: "203.0.113.7")

        assert result.success?
        assert_nil result.data.submitted_by
        assert_equal "reader@example.com", result.data.submitter_email
      end

      test "ignores a submitted email when a user is signed in" do
        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: @user, submitter_email: "typed@example.com", submitter_ip: nil)

        assert result.success?
        assert_nil result.data.submitter_email
        assert_equal @user, result.data.submitted_by
      end

      test "skips content simplification" do
        result = Submission.call(
          list_class: ::Books::List,
          attributes: @attributes.merge(raw_content: "<ul><li>One</li></ul>"),
          user: nil, submitter_email: nil, submitter_ip: nil
        )

        assert result.success?
        assert_nil result.data.simplified_content
      end

      test "rejects a name over the cap" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(name: "a" * 256),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "Name"
        assert_equal 0, ::Books::List.where(source: "The Times").count
      end

      test "rejects raw content over the cap" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(raw_content: "a" * 100_001),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "too long"
      end

      test "rejects whitespace padded raw content over the cap" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(raw_content: " " * 100_001),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "too long"
      end

      test "rejects a duplicate url in any status" do
        ::Books::List.create!(name: "Already here", status: :active,
          url: "https://example.com/greatest")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors, Submission::DUPLICATE_MESSAGE
      end

      test "treats scheme, www and a trailing slash as the same url" do
        ::Books::List.create!(name: "Already here", status: :active,
          url: "http://www.example.com/greatest/")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors, Submission::DUPLICATE_MESSAGE
      end

      test "a duplicate url under a different list type is allowed" do
        ::Music::Albums::List.create!(name: "Same page, albums", status: :active,
          url: "https://example.com/greatest")

        result = Submission.call(list_class: ::Books::List, attributes: @attributes,
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert result.success?
      end

      test "a blank url skips the duplicate check entirely" do
        ::Books::List.create!(name: "No url", status: :active, url: nil)

        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(url: ""),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert result.success?
      end

      test "rejects a submission with no name" do
        result = Submission.call(list_class: ::Books::List,
          attributes: @attributes.merge(name: ""),
          user: nil, submitter_email: nil, submitter_ip: nil)

        assert_not result.success?
        assert_includes result.errors.join, "Name"
      end
    end
  end
end
