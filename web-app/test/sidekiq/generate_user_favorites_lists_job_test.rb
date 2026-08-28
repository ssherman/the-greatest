# frozen_string_literal: true

require "test_helper"

class GenerateUserFavoritesListsJobTest < ActiveSupport::TestCase
  test "runs every generating subclass exactly once" do
    UserList.generating_subclasses.each do |klass|
      Services::Lists::GenerateUserFavorites
        .expects(:call)
        .with(user_list_class: klass)
        .once
        .returns(success_result)
    end

    GenerateUserFavoritesListsJob.new.perform
  end

  test "runs only the named subclass when given one" do
    Services::Lists::GenerateUserFavorites
      .expects(:call)
      .with(user_list_class: ::Books::UserList)
      .returns(success_result)

    GenerateUserFavoritesListsJob.new.perform("Books::UserList")
  end

  test "one domain failing does not stop the others" do
    # Books is first in GENERATING_SUBCLASSES, so if the job aborted on the first
    # failure the .once expectations below would go unmet -- which is exactly
    # what makes this test discriminating.
    Services::Lists::GenerateUserFavorites
      .expects(:call)
      .with(user_list_class: ::Books::UserList)
      .once
      .returns(failure_result)
    (UserList.generating_subclasses - [::Books::UserList]).each do |klass|
      Services::Lists::GenerateUserFavorites
        .expects(:call)
        .with(user_list_class: klass)
        .once
        .returns(success_result)
    end

    # It still raises, so Sidekiq records the failure -- but only after every
    # other domain has been regenerated.
    assert_raises(RuntimeError) { GenerateUserFavoritesListsJob.new.perform }
  end

  test "raises when a domain fails so Sidekiq records the failure" do
    Services::Lists::GenerateUserFavorites.stubs(:call).returns(failure_result)

    error = assert_raises(RuntimeError) { GenerateUserFavoritesListsJob.new.perform }
    assert_includes error.message, "boom"
  end

  test "rejects a class that is not a generating subclass" do
    Services::Lists::GenerateUserFavorites.expects(:call).never

    assert_raises(ArgumentError) do
      GenerateUserFavoritesListsJob.new.perform("Nope::UserList")
    end
  end

  private

  def success_result
    Services::Lists::GenerateUserFavorites::Result.new(
      success?: true, data: {list: nil, item_count: 0, ballot_count: 0}, errors: []
    )
  end

  def failure_result
    Services::Lists::GenerateUserFavorites::Result.new(
      success?: false, data: nil, errors: ["boom"]
    )
  end
end
