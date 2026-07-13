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

    def domain_for_auth
      current_domain&.to_s
    end

    def domain_with_admin_for(record)
      domain = Admin::DomainRouting.domain_for(record)
      domain.to_s if domain && Admin::DomainNav.config_for(domain)
    end

    def access_denied_message(domain)
      "Access denied. You need permission for #{domain || "this"} admin."
    end
  end
end
