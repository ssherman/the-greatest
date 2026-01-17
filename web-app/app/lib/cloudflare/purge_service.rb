# frozen_string_literal: true

module Cloudflare
  class PurgeService
    attr_reader :client, :config

    def initialize(client: nil, config: nil)
      @config = config || Configuration.new
      @client = client || BaseClient.new(@config)
    end

    def purge_all_zones
      zones = config.configured_zones

      if zones.empty?
        return {
          success: false,
          results: {},
          error: "No Cloudflare zones configured"
        }
      end

      purge_zones(zones.keys)
    end

    def purge_zones(domains)
      results = {}

      domains.each do |domain|
        zone_id = config.zone_id(domain)

        if zone_id.blank?
          results[domain] = {success: false, error: "Zone ID not configured"}
          next
        end

        begin
          result = purge_everything(zone_id)
          results[domain] = {
            success: true,
            purge_id: result[:result]["id"],
            response_time: result[:metadata][:response_time]
          }
          log_success(domain, zone_id)
        rescue Exceptions::Error => e
          results[domain] = {success: false, error: e.message}
          log_failure(domain, e)
        end
      end

      {
        success: results.values.all? { |r| r[:success] },
        results: results
      }
    end

    private

    def purge_everything(zone_id)
      endpoint = "zones/#{zone_id}/purge_cache"
      client.post(endpoint, body: {purge_everything: true})
    end

    def log_success(domain, zone_id)
      Rails.logger.info "[Cloudflare] Successfully purged cache for #{domain} (zone: #{zone_id[0..8]}...)"
    end

    def log_failure(domain, error)
      Rails.logger.error "[Cloudflare] Failed to purge cache for #{domain}: #{error.class} - #{error.message}"
    end
  end
end
