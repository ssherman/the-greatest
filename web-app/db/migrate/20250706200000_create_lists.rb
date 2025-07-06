class CreateLists < ActiveRecord::Migration[8.0]
  def change
    create_table :lists do |t|
      t.string :type, null: false
      t.string :name, null: false
      t.text :description
      t.string :source
      t.string :url
      t.integer :status, null: false, default: 0
      t.integer :estimated_quality, null: false, default: 0
      t.boolean :high_quality_source
      t.boolean :category_specific
      t.boolean :location_specific
      t.integer :year_published
      t.boolean :yearly_award
      t.integer :number_of_voters
      t.boolean :voter_count_unknown
      t.boolean :voter_names_unknown
      t.text :formatted_text
      t.text :raw_html

      t.timestamps
    end
  end
end
