# frozen_string_literal: true

class Admin::CloudflareController < Admin::BaseController
  layout "music/admin"
  before_action :require_admin_role!

  def purge_cache
    domain = params[:type]&.to_sym

    unless Cloudflare::Configuration::DOMAINS.include?(domain)
      flash[:error] = "Invalid domain type: #{params[:type]}"
      redirect_back(fallback_location: admin_root_path)
      return
    end

    result = Cloudflare::PurgeService.new.purge_zones([domain])

    if result[:success]
      flash[:success] = "Cache purged successfully for #{domain}"
      log_purge_action("success", [domain.to_s])
    else
      error = result[:results][domain][:error]
      flash[:error] = "Failed to purge #{domain} cache: #{error}"
      log_purge_action("failed", [], [domain.to_s])
    end

    redirect_back(fallback_location: admin_root_path)
  rescue Cloudflare::Exceptions::ConfigurationError => e
    flash[:error] = "Cloudflare configuration error: #{e.message}"
    redirect_back(fallback_location: admin_root_path)
  rescue => e
    Rails.logger.error "[Cloudflare] Unexpected error: #{e.class} - #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    flash[:error] = "An unexpected error occurred while purging cache."
    redirect_back(fallback_location: admin_root_path)
  end

  private

  def require_admin_role!
    unless current_user&.admin?
      redirect_to domain_root_path, alert: "Access denied. Admin role required."
    end
  end

  def format_failures(failed_zones)
    failed_zones.map { |zone, data| "#{zone} (#{data[:error]})" }.join(", ")
  end

  def log_purge_action(status, successful = [], failed = [])
    Rails.logger.info "[Cloudflare] Purge action by #{current_user&.email}: " \
                      "status=#{status}, successful=#{successful}, failed=#{failed}"
  end
end
