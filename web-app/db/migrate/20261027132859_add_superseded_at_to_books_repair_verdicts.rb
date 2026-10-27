class AddSupersededAtToBooksRepairVerdicts < ActiveRecord::Migration[8.1]
  def change
    add_column :books_repair_verdicts, :superseded_at, :datetime
  end
end
