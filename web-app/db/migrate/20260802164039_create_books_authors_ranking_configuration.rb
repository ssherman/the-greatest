class CreateBooksAuthorsRankingConfiguration < ActiveRecord::Migration[8.1]
  CONFIGURATION_NAME = "The Greatest Authors"

  def up
    return if Books::Authors::RankingConfiguration.exists?

    Books::Authors::RankingConfiguration.create!(
      name: CONFIGURATION_NAME,
      description: "Authors ranked by aggregating the scores of their ranked books.",
      global: true,
      primary: true,
      published_at: Time.current,
      apply_list_dates_penalty: false,
      inherit_penalties: false
    )
  end

  # Scoped to the row up created, not destroy_all: if another author ranking
  # configuration has been added since, an unscoped rollback would take it and
  # its ranked items with it.
  def down
    Books::Authors::RankingConfiguration.where(name: CONFIGURATION_NAME).destroy_all
  end
end
