# frozen_string_literal: true

# The recommendation pages (spec §2): results, the four-step wizard, settings.
# Domain-generic in the same way SavedSearchesController is: one set of routes
# on every host, the domain from Current.domain, books-specific data through
# Recommendations::Registry.pages_class_for and books-specific markup in
# app/views/recommendations/<domain>/. Every page varies per user, so nothing
# here is cacheable.
class RecommendationsController < ApplicationController
  include Cacheable
  include DomainLayout
  include MembershipGated

  layout :resolve_layout

  before_action :require_domain_support!
  before_action :prevent_caching
  before_action :require_signed_in!, except: [:show]
  before_action :require_member!, only: [:update_settings]

  def show
    return unless signed_in? # show.html.erb renders the domain pitch
    return redirect_to recommendations_wizard_path(step: 1) unless pages.history?

    @member = current_user.member?
    @limit = @member ? knobs[:member_limit] : knobs[:free_limit]
    result = Recommendations::Engine.call(user: current_user, domain: domain, limit: @limit,
      overrides: recommendation_config.criteria_object.engine_overrides)
    @items = result.success? ? result.data[:items] : []
    @profile = result.success? ? result.data[:profile] : nil
    @state = if @items.any?
      :ok
    elsif !result.success? || result.data[:degraded]
      :unavailable
    else
      :no_matches
    end
    @reason_names = reason_names(@items)
    @taste_names = @profile ? pages.category_names(@profile.scored_ids) : {}
    @counts = @profile&.counts || {}
    @groups = pages.criteria_groups(recommendation_config.criteria_object)
  end

  # Tasks 6 and 7 replace these.
  def search
    head :not_found
  end

  def wizard
    head :not_found
  end

  def settings
    head :not_found
  end

  def update_settings
    head :not_found
  end

  def reset
    head :not_found
  end

  private

  def domain
    Current.domain.to_s
  end

  def require_domain_support!
    raise ActiveRecord::RecordNotFound if Recommendations::Registry.pages_class_for(domain).nil? ||
      ::RecommendationConfig.subclass_for(domain).nil?
  end

  def require_member!
    require_membership!(Recommendations::Registry.membership_feature_for(domain))
  end

  def pages
    @pages ||= Recommendations::Registry.pages_class_for(domain).new(user: current_user)
  end

  # Never written on GET: for_user is find_or_initialize_by.
  def recommendation_config
    @recommendation_config ||= ::RecommendationConfig.subclass_for(domain).for_user(current_user)
  end

  def knobs
    Rails.application.config.x.recommendations
  end

  # {id => name} for every id the page's reasons mention, two queries at most.
  def reason_names(items)
    by_type = items.group_by { |entry| entry[:reason].type }
    category_ids = by_type.fetch(:interests, []).flat_map { |e| e[:reason].ids }
    item_ids = by_type.fetch(:because_of, []).flat_map { |e| e[:reason].ids }
    pages.category_names(category_ids.uniq).merge(pages.item_names(item_ids.uniq))
  end
end
