# == Schema Information
#
# Table name: books_profiles
#
#  id                 :bigint           not null, primary key
#  display_name       :string
#  public             :boolean          default(FALSE), not null
#  show_favorites     :boolean          default(FALSE), not null
#  show_goals         :boolean          default(FALSE), not null
#  show_reading_now   :boolean          default(FALSE), not null
#  show_recently_read :boolean          default(FALSE), not null
#  show_reviews       :boolean          default(FALSE), not null
#  show_stats         :boolean          default(FALSE), not null
#  show_taste         :boolean          default(FALSE), not null
#  show_top_rated     :boolean          default(FALSE), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  user_id            :bigint           not null
#
# Indexes
#
#  index_books_profiles_on_user_id  (user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class Books::Profile < ApplicationRecord
  SECTIONS = %i[stats favorites goals reading_now taste recently_read top_rated reviews].freeze

  belongs_to :user

  before_validation :normalize_display_name

  validates :user_id, uniqueness: true
  validates :display_name, presence: true, length: {in: 2..40}, if: :public?

  def show?(section)
    raise ArgumentError, "unknown profile section: #{section.inspect}" unless SECTIONS.include?(section.to_sym)

    public_send(:"show_#{section}")
  end

  private

  def normalize_display_name
    self.display_name = display_name&.squish
  end
end
