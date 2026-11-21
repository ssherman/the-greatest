# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One audit of a list. The column field_changes is rendered as `changes`.
        # Key order is the order of AdminListAudit in config/api/v1/admin_openapi.yaml.
        class ListAuditResource
          include Alba::Resource

          attributes :id, :status, :verdict

          attribute :user_name do |audit|
            user = audit.user
            user && (user.display_name.presence || user.name.presence || user.email)
          end

          attributes :started_at, :finished_at, :lease_expires_at, :note, :sources

          attribute :changes do |audit|
            audit.field_changes
          end
        end
      end
    end
  end
end
