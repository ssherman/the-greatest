class Music::ListsController < ApplicationController
  include Cacheable

  layout "music/application"

  before_action :load_ranking_configurations, only: [:index]
  before_action :cache_for_index_page, only: [:index]

  def index
    @albums_ranked_lists = @albums_ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Albums::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)

    @songs_ranked_lists = @songs_ranking_configuration.ranked_lists
      .joins(:list)
      .where(lists: {type: "Music::Songs::List"})
      .includes(list: :list_items)
      .order(weight: :desc)
      .limit(50)
  end

  def new
    @list = List.new
  end

  def create
    list_class = list_class_from_type(params[:list_type])

    if list_class.nil?
      @list = List.new(list_params)
      @list.errors.add(:base, "Please select a list type (Album List or Song List)")
      render :new, status: :unprocessable_entity
      return
    end

    @list = list_class.new(list_params)
    @list.status = :unapproved
    @list.submitted_by = current_user if current_user

    if @list.save
      redirect_to music_lists_path, notice: "Thank you for your submission! Your list will be reviewed shortly."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def load_ranking_configurations
    @albums_ranking_configuration = Music::Albums::RankingConfiguration.default_primary
    @songs_ranking_configuration = Music::Songs::RankingConfiguration.default_primary
  end

  def list_class_from_type(list_type)
    case list_type
    when "albums"
      Music::Albums::List
    when "songs"
      Music::Songs::List
    end
  end

  def list_params
    params.require(:list).permit(
      :name,
      :description,
      :source,
      :url,
      :year_published,
      :number_of_voters,
      :num_years_covered,
      :location_specific,
      :category_specific,
      :yearly_award,
      :voter_count_estimated,
      :voter_names_unknown,
      :voter_count_unknown,
      :raw_html
    )
  end
end
