class Admin::Games::CompaniesController < Admin::Games::BaseController
  before_action :set_company, only: [:show, :edit, :update, :destroy]
  before_action :authorize_company, only: [:show, :edit, :update, :destroy]

  def index
    authorize Games::Company
    load_companies_for_index
  end

  def show
    @company = Games::Company
      .includes(
        :identifiers,
        :primary_image,
        game_companies: {game: [:platforms]},
        images: {file_attachment: :blob}
      )
      .find(params[:id])
  end

  def new
    @company = Games::Company.new
    authorize @company
  end

  def create
    @company = Games::Company.new(company_params)
    authorize @company

    if @company.save
      redirect_to admin_games_company_path(@company), notice: "Company created successfully."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @company.update(company_params)
      redirect_to admin_games_company_path(@company), notice: "Company updated successfully."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @company.destroy!
    redirect_to admin_games_companies_path, notice: "Company deleted successfully."
  end

  def search
    sanitized = "%#{Games::Company.sanitize_sql_like(params[:q].to_s)}%"
    companies = Games::Company.where("name ILIKE ?", sanitized)
      .order(:name).limit(20)

    render json: companies.map { |c| {value: c.id, text: "#{c.name}#{" (#{c.country})" if c.country.present?}"} }
  end

  private

  def set_company
    @company = Games::Company.find(params[:id])
  end

  def authorize_company
    authorize @company
  end

  def load_companies_for_index
    @companies = Games::Company.all

    if params[:q].present?
      sanitized = "%#{Games::Company.sanitize_sql_like(params[:q])}%"
      @companies = @companies.where("name ILIKE ?", sanitized)
    end

    sort_column = sortable_column(params[:sort])
    @companies = @companies.order(sort_column)
    @pagy, @companies = pagy(@companies, limit: 25)
  end

  def sortable_column(column)
    allowed_columns = {
      "id" => "games_companies.id",
      "name" => "games_companies.name",
      "country" => "games_companies.country",
      "year_founded" => "games_companies.year_founded",
      "created_at" => "games_companies.created_at"
    }

    allowed_columns.fetch(column, "games_companies.name")
  end

  def company_params
    params.require(:games_company).permit(:name, :description, :country, :year_founded)
  end
end
