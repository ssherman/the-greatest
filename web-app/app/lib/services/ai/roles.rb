# frozen_string_literal: true

module Services
  module Ai
    # Reads config.x.ai.roles. The only place that does, so a test can stub
    # one method to change which model a task runs on.
    module Roles
      Role = Struct.new(:name, :provider, :model, :tools, keyword_init: true)

      class UnknownRole < ArgumentError; end

      def self.resolve(name)
        name = name.to_sym
        config = configured[name]
        if config.nil?
          raise UnknownRole, "Unknown AI role #{name.inspect}; roles are #{names.join(", ")}"
        end

        Role.new(
          name: name,
          provider: config.fetch(:provider).to_sym,
          model: config.fetch(:model),
          tools: Array(config[:tools]).map(&:to_sym).freeze
        ).freeze
      end

      def self.names
        configured.keys
      end

      def self.configured
        Rails.application.config.x.ai.roles
      end
      private_class_method :configured
    end
  end
end
