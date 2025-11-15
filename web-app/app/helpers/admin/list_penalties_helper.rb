module Admin::ListPenaltiesHelper
  def available_penalties(list)
    media_type = list.type.split("::").first

    Penalty
      .static
      .where("type IN (?, ?)", "Global::Penalty", "#{media_type}::Penalty")
      .where.not(id: list.penalties.pluck(:id))
      .order(:name)
  end
end
