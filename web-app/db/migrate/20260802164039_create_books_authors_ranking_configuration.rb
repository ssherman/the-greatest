class CreateBooksAuthorsRankingConfiguration < ActiveRecord::Migration[8.1]
  def up
    return if Books::Authors::RankingConfiguration.exists?

    Books::Authors::RankingConfiguration.create!(
      name: "The Greatest Authors",
      description: "Authors ranked by aggregating the scores of their ranked books.",
      global: true,
      primary: true,
      published_at: Time.current,
      apply_list_dates_penalty: false,
      inherit_penalties: false
    )
  end

  def down
    Books::Authors::RankingConfiguration.destroy_all
  end
end
