module Services
  module Corrections
    # Resolves a correctable_type string that arrived in a request.
    #
    # Legacy called params[:changeable_type].constantize directly, which resolves
    # any constant name an attacker cares to send. This resolves ONLY names that
    # are already keys of Admin::DomainRouting::ENTITIES -- the registry that
    # already drives descriptions, category items and admin paths -- and then only
    # if the resulting class actually includes Correctable. Anything else is nil,
    # which callers turn into a 400.
    #
    # ::Admin and ::Books are root-anchored: Services::Books exists, so a bare
    # Books::Book written inside Services::Corrections resolves to
    # Services::Books::Book and raises NameError.
    module TypeRegistry
      def self.resolve(type_name)
        name = type_name.to_s
        return nil if name.blank?
        return nil unless ::Admin::DomainRouting::ENTITIES.key?(name)

        klass = name.safe_constantize
        return nil unless klass.respond_to?(:correctable_fields)

        klass
      end

      def self.domain_for(type_name)
        ::Admin::DomainRouting::ENTITIES.dig(type_name.to_s, :domain)
      end

      def self.types_for_domain(domain)
        ::Admin::DomainRouting::ENTITIES.filter_map do |name, config|
          name if config[:domain] == domain&.to_sym && resolve(name)
        end
      end
    end
  end
end
