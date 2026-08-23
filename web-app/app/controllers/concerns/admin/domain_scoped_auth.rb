module Admin
  module DomainScopedAuth
    extend ActiveSupport::Concern

    private

    def authenticate_admin!
      return if current_user&.admin? || current_user&.editor?

      domain = domain_for_auth
      return if domain.present? && current_user&.can_access_domain?(domain)

      redirect_to domain_root_path, alert: access_denied_message(domain)
    end

    # Gate a mutating action on write access to the resolved (parent) domain.
    # authenticate_admin! only proves domain *access* (true for viewers); shared
    # controllers with no Pundit layer (images, category items) call this to keep
    # read-only domain users from mutating, matching ApplicationPolicy#update?.
    def require_domain_write!
      return if current_user&.admin? || current_user&.editor?

      domain = domain_for_auth
      return if domain.present? && current_user&.can_write_in_domain?(domain)

      redirect_to domain_root_path, alert: access_denied_message(domain)
    end

    # Gate a destroying action on DELETE access to the resolved domain.
    # require_domain_write! is not enough: can_write? is editor|moderator|admin
    # while can_delete? is moderator|admin, so an editor passes the write guard
    # and could remove records through a crafted request even where the UI hides
    # the Delete control. Controllers with a Pundit layer already get this from
    # ApplicationPolicy#destroy?, which asks can_delete?; this is the equivalent
    # for the ones that have none.
    def require_domain_delete!
      return if current_user&.admin? || current_user&.editor?

      domain = domain_for_auth
      return if domain.present? && current_user&.can_delete_in_domain?(domain)

      redirect_to domain_root_path, alert: access_denied_message(domain)
    end

    def domain_for_auth
      parent = domain_auth_parent
      return Admin::DomainRouting.domain_for(parent)&.to_s if parent

      current_domain&.to_s
    end

    # Controllers that manage a nested/polymorphic parent (images, category items)
    # override this to authorize against the parent record's domain rather than the
    # request host. Default nil → fall back to current_domain (behavior-neutral).
    def domain_auth_parent
      nil
    end

    def domain_with_ranking_configuration_admin_for(ranking_configuration)
      config = Admin::DomainRouting.ranking_configuration_config(ranking_configuration)
      return nil if config.nil? || config[:path].blank?

      config[:domain].to_s
    end

    def access_denied_message(domain)
      "Access denied. You need permission for #{domain || "this"} admin."
    end
  end
end
