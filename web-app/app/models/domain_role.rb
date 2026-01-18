# == Schema Information
#
# Table name: domain_roles
#
#  id               :bigint           not null, primary key
#  domain           :integer          not null
#  permission_level :integer          default("viewer"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_domain_roles_on_domain              (domain)
#  index_domain_roles_on_permission_level    (permission_level)
#  index_domain_roles_on_user_id             (user_id)
#  index_domain_roles_on_user_id_and_domain  (user_id,domain) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class DomainRole < ApplicationRecord
  belongs_to :user

  enum :domain, {music: 0, games: 1, books: 2, movies: 3}
  enum :permission_level, {viewer: 0, editor: 1, moderator: 2, admin: 3}

  validates :user_id, uniqueness: {scope: :domain, message: "already has a role for this domain"}
  validates :domain, presence: true
  validates :permission_level, presence: true

  # Permission level hierarchy checks
  def can_read?
    true # all permission levels can read
  end

  def can_write?
    editor? || moderator? || admin?
  end

  def can_delete?
    moderator? || admin?
  end

  def can_manage?
    admin?
  end
end
