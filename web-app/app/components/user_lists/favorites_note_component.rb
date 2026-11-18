# frozen_string_literal: true

# Tells the owner that a Favorites list feeds the site rankings, and that its
# order matters. Renders nothing for lists that don't count toward rankings.
class UserLists::FavoritesNoteComponent < ViewComponent::Base
  def initialize(user_list:)
    @user_list = user_list
  end

  def render?
    user_list.counts_toward_rankings?
  end

  private

  attr_reader :user_list
end
