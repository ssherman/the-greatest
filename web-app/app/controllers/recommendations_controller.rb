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

  GATED_STEPS = (3..4)
  NEEDS_HISTORY_ALERT = "Add a favorite book or a book you have read before rating books or setting preferences."

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

  def search
    @query = params[:q].to_s.strip.first(200)
    @books = @query.blank? ? [] : pages.search(@query)
    render layout: false
  end

  def wizard
    @step = params[:step].to_i
    @unlocked = pages.history?
    if GATED_STEPS.cover?(@step) && !@unlocked
      return redirect_to recommendations_wizard_path(step: 2), alert: NEEDS_HISTORY_ALERT
    end

    case @step
    when 1
      @favorites = pages.favorites
      @favorites_list = pages.list(:favorites)
    when 2 then @read = pages.read_books
    when 3
      @unrated = pages.unrated_read
      @rated = pages.rated
    when 4
      assign_settings_form(locked: !current_user.member?)
    end
  end

  def settings
    assign_settings_form(locked: !current_user.member?)
  end

  def update_settings
    permitted = criteria_params
    if permitted
      recommendation_config.criteria = recommendation_config.class.criteria_params_class.call(permitted)
      return redirect_to recommendations_path, notice: "Settings saved." if recommendation_config.save
    end

    assign_settings_form(locked: false)
    render :settings, status: :unprocessable_entity
  end

  def reset
    recommendation_config.destroy if recommendation_config.persisted?
    redirect_to recommendations_wizard_path(step: 1), status: :see_other, notice: "Settings reset. Start again from your favorites."
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

  CRITERIA_PARAMS = [:genre_match_mode, :first_year_published_gt, :first_year_published_lt, :max_ranked_position, :depth,
    {book_length: [], included_category_ids: [], excluded_category_ids: []}].freeze

  # nil when the criteria is not a hash (a hand-rolled `criteria=x` would
  # otherwise raise on permit and 500), so the caller can answer 422.
  def criteria_params
    raw = params.fetch(:recommendation_config, {})[:criteria]
    return {} if raw.nil?
    return nil unless raw.respond_to?(:permit)

    raw.permit(*CRITERIA_PARAMS)
  end

  def assign_settings_form(locked:)
    @step = 4
    @config = recommendation_config
    @locked = locked
    @picked_categories = pages.picked_categories(@config.criteria_object)
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
