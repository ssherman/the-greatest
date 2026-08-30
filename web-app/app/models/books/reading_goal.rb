# == Schema Information
#
# Table name: books_reading_goals
#
#  id           :bigint           not null, primary key
#  description  :text
#  ends_on      :date             not null
#  name         :string           not null
#  public       :boolean          default(FALSE), not null
#  starts_on    :date             not null
#  target_count :integer          not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
# Indexes
#
#  index_books_reading_goals_for_public_date_lookup  (user_id,public,starts_on,ends_on)
#  index_books_reading_goals_on_user_id              (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
module Books
  class ReadingGoal < ApplicationRecord
    belongs_to :user

    validates :name, presence: true
    validates :target_count, numericality: {only_integer: true, greater_than: 0}
    validates :starts_on, :ends_on, presence: true
    validates :public, inclusion: {in: [true, false]}
    validate :ends_on_not_before_starts_on

    scope :public_goals, -> { where(public: true) }
    scope :owned_by, ->(user) { where(user: user) }
    scope :active_on, ->(date) {
      where("starts_on <= ? AND ends_on >= ?", date, date).order(:ends_on, :id)
    }
    scope :upcoming_on, ->(date) { where("starts_on > ?", date).order(:starts_on, :id) }
    scope :finished_on, ->(date) { where("ends_on < ?", date).order(ends_on: :desc, id: :desc) }

    private

    def ends_on_not_before_starts_on
      return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

      errors.add(:ends_on, "must be on or after the start date")
    end
  end
end
