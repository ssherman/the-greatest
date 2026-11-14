class AddReviewedViaToBooksRepairVerdicts < ActiveRecord::Migration[8.1]
  def change
    add_column :books_repair_verdicts, :reviewed_via, :integer
  end
end
