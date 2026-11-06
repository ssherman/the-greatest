class AddUndoToBooksVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :books_verification_findings, :undone_at, :datetime
    add_column :books_verification_findings, :undo_action, :integer
  end
end
