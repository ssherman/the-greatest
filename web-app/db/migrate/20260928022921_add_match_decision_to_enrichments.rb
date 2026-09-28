class AddMatchDecisionToEnrichments < ActiveRecord::Migration[8.1]
  def change
    add_reference :enrichments, :match_decision, foreign_key: {on_delete: :nullify}, index: true
  end
end
