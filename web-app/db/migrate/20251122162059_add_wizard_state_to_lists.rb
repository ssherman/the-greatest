class AddWizardStateToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :wizard_state, :jsonb, default: {}
  end
end
