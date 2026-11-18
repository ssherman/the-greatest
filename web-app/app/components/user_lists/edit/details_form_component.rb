# frozen_string_literal: true

# The Edit page's name / description / visibility form. Its root id lets the
# update action replace it in place; failures go to #list-details-errors.
class UserLists::Edit::DetailsFormComponent < ViewComponent::Base
  def initialize(user_list:)
    @user_list = user_list
  end

  private

  attr_reader :user_list
end
