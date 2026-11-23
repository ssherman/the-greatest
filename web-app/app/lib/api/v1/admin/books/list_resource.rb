# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # A books list as a row of the search. `params` carries the page's
        # lookups from ListResource.lookups: :item_counts, :weights ({list_id =>
        # weight on the default primary}) and :last_audits ({list_id => latest
        # finished audit}). ListResource.row builds them for a single list.
        # Key order is the order of AdminList in config/api/v1/admin_openapi.yaml.
        # Root-anchor every ::Books:: reference.
        class ListResource
          include Alba::Resource

          # The weight of each list on the default primary configuration; empty
          # when there is none.
          def self.primary_weights(list_ids)
            primary = ::Books::RankingConfiguration.default_primary
            return {} unless primary

            ::RankedList.where(ranking_configuration_id: primary.id, list_id: list_ids).pluck(:list_id, :weight).to_h
          end

          def self.last_finished_audits(list_ids)
            ::ListAudit.done.where(list_id: list_ids).order(finished_at: :desc, id: :desc)
              .each_with_object({}) { |audit, latest| latest[audit.list_id] ||= audit }
          end

          def self.lookups(lists)
            ids = lists.map(&:id)
            {
              item_counts: ::ListItem.where(list_id: ids).group(:list_id).count,
              weights: primary_weights(ids),
              last_audits: last_finished_audits(ids)
            }
          end

          def self.row(list)
            new(list, params: lookups([list])).to_h
          end

          attributes :id, :name, :source, :year_published, :status, :items_need_revision

          attribute :item_count do |list|
            params[:item_counts].fetch(list.id, 0)
          end

          attribute :weight do |list|
            params[:weights][list.id]
          end

          attribute :last_audit do |list|
            audit = params[:last_audits][list.id]
            audit && {id: audit.id, status: audit.status, verdict: audit.verdict, finished_at: audit.finished_at}
          end
        end
      end
    end
  end
end
