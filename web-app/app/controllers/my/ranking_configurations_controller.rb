# User-owned ranking configurations (spec: docs/superpowers/specs/
# 2026-09-12-user-ranking-configurations-design.md). Global routes; the
# domain comes from Current.domain via RankingConfigurations::Registry.
# Owner-only and never cached. The public view of a configuration is its
# /rc/:id page, gated by RankingConfigurationGating.
class My::RankingConfigurationsController < ApplicationController
  include Cacheable
  include DomainLayout
  include RankingConfigurationOwnerScoped

  layout :resolve_layout

  before_action :prevent_caching
  before_action :require_domain_support!
  before_action :require_signed_in!
  before_action :set_ranking_configuration, only: [:show, :edit, :update, :destroy]

  def index
    types = domain_entries.map(&:ranking_configuration_class)
    @ranking_configurations = current_user.ranking_configurations.where(type: types).order(created_at: :desc).to_a
    counts = @ranking_configurations.group_by(&:type).transform_values(&:size)
    @at_limit = types.all? { |type| counts.fetch(type, 0) >= ::RankingConfiguration::MAX_PER_USER }
  end

  def new
    if domain_entries.many? && params[:kind].blank?
      @entries = domain_entries
      return render :choose_kind
    end

    @entry = entry_for_new
    @start = start_param
    @ranking_configuration = @entry.ranking_configuration_class.constantize.new(new_defaults)
    authorize @ranking_configuration, policy_class: RankingConfigurationPolicy
    @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: default_penalty_values)
    @seed_lists = true
    @official_list_count = official_list_count
  end

  def create
    @entry = entry_for_new
    @start = start_param
    authorize ::RankingConfiguration, policy_class: RankingConfigurationPolicy

    result = Services::RankingConfigurations::Create.call(
      user: current_user,
      entry: @entry,
      attributes: configuration_params,
      penalties: penalty_params(@entry),
      start: @start,
      seed_lists: params[:seed_lists] == "1"
    )

    if result.success?
      redirect_to my_ranking_configuration_path(result.data[:ranking_configuration]),
        notice: "Your ranking was created. We're calculating it now — this usually takes a few minutes.",
        status: :see_other
    else
      @ranking_configuration = result.data[:ranking_configuration]
      @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: submitted_penalty_values(@entry))
      @seed_lists = params[:seed_lists] == "1"
      @official_list_count = official_list_count
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @entry = current_entry
    @lists_count = @ranking_configuration.ranked_lists.count
    @penalties_on = @ranking_configuration.penalty_applications.count
    @penalties_total = ::RankingConfigurations::Registry.penalties_for(@entry).count
  end

  def edit
    @entry = current_entry
    @penalty_groups = ::RankingConfigurations::PenaltyRows.call(
      entry: @entry,
      values: @ranking_configuration.penalty_applications.pluck(:penalty_id, :value).to_h
    )
  end

  def update
    @entry = current_entry
    result = Services::RankingConfigurations::Save.call(
      config: @ranking_configuration,
      entry: @entry,
      attributes: configuration_params,
      penalties: penalty_params(@entry)
    )

    if result.success?
      redirect_to my_ranking_configuration_path(@ranking_configuration), notice: "Your ranking was saved.", status: :see_other
    else
      @penalty_groups = ::RankingConfigurations::PenaltyRows.call(entry: @entry, values: submitted_penalty_values(@entry))
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @ranking_configuration.destroy
    redirect_to my_ranking_configurations_path, notice: "Your ranking was deleted.", status: :see_other
  end

  private

  def entry_for_new
    return domain_entries.first if domain_entries.one?

    ::RankingConfigurations::Registry.find(Current.domain, params[:kind]) || raise(ActiveRecord::RecordNotFound)
  end

  def start_param
    (params[:start] == "scratch") ? :scratch : :official
  end

  def official_configuration
    return @official_configuration if defined?(@official_configuration)

    @official_configuration = @entry.ranking_configuration_class.constantize.default_primary
  end

  def official_list_count
    official_configuration&.ranked_lists&.count.to_i
  end

  # The new form starts from the official configuration unless the visitor
  # chose to start from scratch (model defaults).
  def new_defaults
    return {} if @start == :scratch || official_configuration.nil?

    official_configuration.slice(*::RankingConfiguration::RANKING_SETTINGS)
      .merge("min_list_weight" => official_configuration.weight_floor)
  end

  def default_penalty_values
    return {} if @start == :scratch || official_configuration.nil?

    official_configuration.penalty_applications.pluck(:penalty_id, :value).to_h
  end

  def configuration_params
    params.require(:ranking_configuration).permit(:name, :description, :user_shared, *::RankingConfiguration::RANKING_SETTINGS)
  end

  # Only the catalogue's ids are permitted, each with enabled + value. A
  # hand-built request can send penalties as a scalar; that is an empty set,
  # not a 500.
  def penalty_params(entry)
    raw = params[:penalties]
    return {} unless raw.is_a?(ActionController::Parameters)

    allowed = ::RankingConfigurations::Registry.penalties_for(entry).pluck(:id)
      .index_with { [:enabled, :value] }.transform_keys(&:to_s)
    raw.permit(allowed).to_h
  end

  def submitted_penalty_values(entry)
    penalty_params(entry).each_with_object({}) do |(id, row), values|
      values[id.to_i] = row["value"].to_i if ActiveModel::Type::Boolean.new.cast(row["enabled"])
    end
  end
end
