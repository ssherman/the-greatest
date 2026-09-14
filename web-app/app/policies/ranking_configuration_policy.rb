# frozen_string_literal: true

# Ownership policy for the /my/rankings surface. Separate from the admin
# Books::RankingConfigurationPolicy (domain roles, bulk actions): the question
# here is "does this user own this row", and neither admins nor domain
# editors get that answer for someone else's configuration.
#
# Pundit's default policy for a Books::RankingConfiguration record IS the
# admin one, so every authorize call must pass
# policy_class: RankingConfigurationPolicy explicitly.
#
# create? is where a membership gate goes later.
class RankingConfigurationPolicy < ApplicationPolicy
  def index? = user.present?
  def create? = user.present?
  def new? = create?
  def show? = owner?
  def update? = owner?
  def edit? = update?
  def destroy? = owner?
  def refresh? = owner?
  def state? = owner?
  def manage_lists? = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user

      scope.where(user: user)
    end
  end

  private

  def owner? = user.present? && record.respond_to?(:user_id) && record.user_id == user.id
end
