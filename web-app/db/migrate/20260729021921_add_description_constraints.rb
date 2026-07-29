class AddDescriptionConstraints < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :descriptions,
      "length(btrim(content)) > 0",
      name: "descriptions_content_not_blank"

    # rank = 1 is :preferred (deprecated: -1, normal: 0, preferred: 1)
    add_index :descriptions, [:describable_type, :describable_id, :kind, :locale],
      unique: true, where: "rank = 1", name: "index_descriptions_one_preferred_per_key"
  end
end
