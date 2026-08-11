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

    # Purges specific URLs from one zone. Unlike purge_zones, which drops an
    # entire zone's cache, this touches only the pages named -- a review write
    # must not evict ~156k book pages.
    #
    # Purge-by-URL is available on the Pro plan (Cloudflare moved every purge
    # method to every plan) with limits far above this feature's volume.
    #
    # Never raises: a failed purge degrades to the page staying cached until it
    # expires, which is the pre-existing behaviour, and the caller is a
    # background job with nothing useful to do about it.
    def purge_urls(domain, urls)
      return {success: false, error: "No URLs given"} if urls.blank?

      zone_id = config.zone_id(domain)
      return {success: false, error: "Zone ID not configured for #{domain}"} if zone_id.blank?

      result = client.post("zones/#{zone_id}/purge_cache", body: {files: urls})
      log_success(domain, zone_id)
      {success: true, purge_id: result[:result]["id"]}
    rescue Exceptions::Error => e
      log_failure(domain, e)
      {success: false, error: e.message}
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
