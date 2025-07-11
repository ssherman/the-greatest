# == Schema Information
#
# Table name: movies_credits
#
#  id              :bigint           not null, primary key
#  character_name  :string
#  creditable_type :string           not null
#  position        :integer
#  role            :integer          default("director"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  creditable_id   :bigint           not null
#  person_id       :bigint           not null
#
# Indexes
#
#  index_movies_credits_on_creditable                         (creditable_type,creditable_id)
#  index_movies_credits_on_creditable_type_and_creditable_id  (creditable_type,creditable_id)
#  index_movies_credits_on_person_id                          (person_id)
#  index_movies_credits_on_person_id_and_role                 (person_id,role)
#
# Foreign Keys
#
#  fk_rails_...  (person_id => movies_people.id)
#
module Movies
  class Credit < ApplicationRecord
    # Associations
    belongs_to :person, class_name: "Movies::Person"
    belongs_to :creditable, polymorphic: true

    # Enums
    enum :role, {
      director: 0, producer: 1, screenwriter: 2, actor: 3, actress: 4,
      cinematographer: 5, editor: 6, composer: 7, production_designer: 8,
      costume_designer: 9, makeup_artist: 10, stunt_coordinator: 11,
      visual_effects: 12, sound_designer: 13, casting_director: 14,
      executive_producer: 15, assistant_director: 16, script_supervisor: 17
    }

    # Validations
    validates :person, presence: true
    validates :creditable, presence: true
    validates :role, presence: true, inclusion: {in: roles.keys}
    validates :position, numericality: {only_integer: true, greater_than: 0}, allow_nil: true

    # Scopes
    scope :by_role, ->(role) { where(role: role) }
    scope :ordered_by_position, -> { order(:position) }
    scope :for_movie, ->(movie) { where(creditable: movie) }
    scope :for_release, ->(release) { where(creditable: release) }
  end
end
