class AddRawToExternalRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :external_records, :raw, :binary
  end
end
