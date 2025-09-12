class AddPrimaryToImages < ActiveRecord::Migration[8.0]
  def change
    add_column :images, :primary, :boolean, default: false, null: false
    add_index :images, [:parent_type, :parent_id, :primary], name: "index_images_on_parent_and_primary"
  end
end
