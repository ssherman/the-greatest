# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # One books list with everything an auditor needs: the row keys, the
        # editable fields, penalties, the weight breakdown and audits. Every
        # controller that answers with a list calls ListFullResource.for(list)
        # so the shape is identical across them. Key order is the order of
        # AdminListFull in config/api/v1/admin_openapi.yaml.
        class ListFullResource < ListResource
          FIELDS = %w[name description source source_country_origin url year_published number_of_voters
            num_years_covered yearly_award high_quality_source category_specific location_specific
            creator_specific voter_count_estimated voter_count_unknown voter_names_unknown estimated_quality].freeze
          RECENT_AUDITS = 5

          def self.for(list)
            primary = ::Books::RankingConfiguration.default_primary
            ranked = primary && ::RankedList.find_by(ranking_configuration_id: primary.id, list_id: list.id)
            values = primary ? ::PenaltyApplication.where(ranking_configuration_id: primary.id).pluck(:penalty_id, :value).to_h : {}
            audits = list.list_audits.where(status: %i[finished released])
              .order(Arel.sql("COALESCE(list_audits.finished_at, list_audits.updated_at) DESC"), id: :desc)
              .limit(RECENT_AUDITS).includes(:user).to_a
            new(list, params: lookups([list]).merge(
              ranked: ranked, values: values, audits: audits,
              open_audit: list.list_audits.open.includes(:user).first,
              penalties: list.penalties.order(:id).to_a
            )).to_h
          end

          attributes(*(FIELDS - %w[name source year_published]))

          attribute :auto_generated do |list|
            list.auto_generated?
          end

          attribute :has_raw_content do |list|
            list.raw_content.present?
          end

          attribute :penalties do |list|
            params[:penalties].map do |penalty|
              {
                id: penalty.id, name: penalty.name, kind: penalty.dynamic? ? "dynamic" : "static",
                category: penalty.category, value_on_primary: params[:values][penalty.id]
              }
            end
          end

          attribute :weight_details do |list|
            params[:ranked]&.calculated_weight_details
          end

          attribute :weight_computed_at do |list|
            params[:ranked]&.updated_at
          end

          attribute :open_audit do |list|
            audit = params[:open_audit]
            audit && ListAuditResource.new(audit).to_h
          end

          attribute :audits do |list|
            params[:audits].map { |audit| ListAuditResource.new(audit).to_h }
          end
        end
      end
    end
  end
end
