# frozen_string_literal: true

# A reader's own book submissions. Only the owner may cancel or dismiss one;
# admins review submissions elsewhere, never through the reader's endpoints.
class Books::BookSubmissionPolicy < ApplicationPolicy
  def create? = user.present?

  def cancel? = owner?

  def dismiss? = owner?

  private

  def owner? = user.present? && record.user_id == user.id
end
