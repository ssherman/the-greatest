require "test_helper"

class Books::BookSubmissionPolicyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:regular_user)
    @submission = Books::BookSubmission.new(user: @owner)
  end

  test "the owner may create, cancel and dismiss" do
    policy = Books::BookSubmissionPolicy.new(@owner, @submission)

    assert policy.create?
    assert policy.cancel?
    assert policy.dismiss?
  end

  test "another user, an admin and an anonymous visitor may not cancel or dismiss" do
    [users(:editor_user), users(:admin_user), nil].each do |user|
      policy = Books::BookSubmissionPolicy.new(user, @submission)

      refute policy.cancel?
      refute policy.dismiss?
    end
  end

  test "an anonymous visitor may not create" do
    refute Books::BookSubmissionPolicy.new(nil, @submission).create?
  end
end
