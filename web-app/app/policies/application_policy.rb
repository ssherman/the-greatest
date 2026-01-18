# frozen_string_literal: true

# Base policy for all domain resources.
# Provides domain-aware authorization with global admin bypass.
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  # Override in subclasses to specify domain (e.g., "music", "games")
  def domain
    nil
  end

  # Global admin bypass
  def global_admin?
    user&.admin?
  end

  # Global editor bypass (for backward compatibility)
  def global_editor?
    user&.editor?
  end

  # Global role that bypasses domain checks (admin or editor)
  def global_role?
    global_admin? || global_editor?
  end

  # Get the user's domain role for this policy's domain
  def domain_role
    return nil unless user && domain
    @domain_role ||= user.domain_role_for(domain)
  end

  # Default policy methods - all return false unless overridden
  def index?
    global_role? || domain_role&.can_read?
  end

  def show?
    global_role? || domain_role&.can_read?
  end

  def create?
    global_role? || domain_role&.can_write?
  end

  def new?
    create?
  end

  def update?
    global_role? || domain_role&.can_write?
  end

  def edit?
    update?
  end

  def destroy?
    global_role? || domain_role&.can_delete?
  end

  # For system actions like cache purging, imports, rankings
  def manage?
    global_admin? || domain_role&.can_manage?
  end

  class Scope
    attr_reader :user, :scope

    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    # Override in subclasses to specify domain
    def domain
      nil
    end

    def resolve
      if user&.admin? || user&.editor?
        scope.all
      elsif user&.can_access_domain?(domain)
        scope.all
      else
        scope.none
      end
    end
  end
end
