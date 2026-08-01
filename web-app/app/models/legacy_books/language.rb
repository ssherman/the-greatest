# == Schema Information
#
# Table name: languages
#
#  id          :bigint           not null, primary key
#  description :text
#  name        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_languages_on_name  (name) UNIQUE
#
module LegacyBooks
  class Language < Record
    self.table_name = "languages"
  end
end
