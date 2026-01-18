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
require "test_helper"

class DomainRoleTest < ActiveSupport::TestCase
  def setup
    @user = users(:contractor_user)
    @music_editor = domain_roles(:music_editor)
  end

  # Validation tests
  test "validates uniqueness of user and domain" do
    duplicate = DomainRole.new(
      user: @user,
      domain: :music,
      permission_level: :viewer
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "already has a role for this domain"
  end

  test "validates presence of domain" do
    role = DomainRole.new(user: @user, permission_level: :editor)
    assert_not role.valid?
    assert_includes role.errors[:domain], "can't be blank"
  end

  test "validates presence of permission_level" do
    role = DomainRole.new(user: @user, domain: :books)
    # permission_level has a default so this should be valid
    assert role.valid?
  end

  # Permission level tests - viewer
  test "viewer can read" do
    role = DomainRole.new(permission_level: :viewer)
    assert role.can_read?
  end

  test "viewer cannot write" do
    role = DomainRole.new(permission_level: :viewer)
    assert_not role.can_write?
  end

  test "viewer cannot delete" do
    role = DomainRole.new(permission_level: :viewer)
    assert_not role.can_delete?
  end

  test "viewer cannot manage" do
    role = DomainRole.new(permission_level: :viewer)
    assert_not role.can_manage?
  end

  # Permission level tests - editor
  test "editor can read" do
    role = DomainRole.new(permission_level: :editor)
    assert role.can_read?
  end

  test "editor can write" do
    role = DomainRole.new(permission_level: :editor)
    assert role.can_write?
  end

  test "editor cannot delete" do
    role = DomainRole.new(permission_level: :editor)
    assert_not role.can_delete?
  end

  test "editor cannot manage" do
    role = DomainRole.new(permission_level: :editor)
    assert_not role.can_manage?
  end

  # Permission level tests - moderator
  test "moderator can read" do
    role = DomainRole.new(permission_level: :moderator)
    assert role.can_read?
  end

  test "moderator can write" do
    role = DomainRole.new(permission_level: :moderator)
    assert role.can_write?
  end

  test "moderator can delete" do
    role = DomainRole.new(permission_level: :moderator)
    assert role.can_delete?
  end

  test "moderator cannot manage" do
    role = DomainRole.new(permission_level: :moderator)
    assert_not role.can_manage?
  end

  # Permission level tests - admin
  test "admin can read" do
    role = DomainRole.new(permission_level: :admin)
    assert role.can_read?
  end

  test "admin can write" do
    role = DomainRole.new(permission_level: :admin)
    assert role.can_write?
  end

  test "admin can delete" do
    role = DomainRole.new(permission_level: :admin)
    assert role.can_delete?
  end

  test "admin can manage" do
    role = DomainRole.new(permission_level: :admin)
    assert role.can_manage?
  end

  # Domain enum tests
  test "domain enum values" do
    assert_equal({"music" => 0, "games" => 1, "books" => 2, "movies" => 3}, DomainRole.domains)
  end

  # Permission level enum tests
  test "permission_level enum values" do
    assert_equal({"viewer" => 0, "editor" => 1, "moderator" => 2, "admin" => 3}, DomainRole.permission_levels)
  end
end
