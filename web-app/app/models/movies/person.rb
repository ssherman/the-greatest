module Movies
  class Person < ApplicationRecord
    extend FriendlyId
    friendly_id :name, use: [:slugged, :finders]

    # Enums
    enum :gender, {male: 0, female: 1, non_binary: 2, other: 3}

    # Associations
    has_many :credits, class_name: "Movies::Credit", foreign_key: "person_id", dependent: :destroy
    has_many :memberships, class_name: "Movies::Membership", foreign_key: "person_id", dependent: :destroy

    # Validations
    validates :name, presence: true
    validates :country, length: {is: 2}, allow_nil: true
    validates :gender, inclusion: {in: genders.keys}, allow_nil: true
    validate :died_on_after_born_on

    private

    def died_on_after_born_on
      if born_on.present? && died_on.present? && died_on < born_on
        errors.add(:died_on, "must be after date of birth")
      end
    end
  end
end
