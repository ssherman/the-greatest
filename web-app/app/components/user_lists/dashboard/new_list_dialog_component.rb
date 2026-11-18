# frozen_string_literal: true

class UserLists::Dashboard::NewListDialogComponent < ViewComponent::Base
  # types: the domain's UserList subclasses (Array<Class>).
  def initialize(types:)
    @types = types
  end

  private

  attr_reader :types
end
