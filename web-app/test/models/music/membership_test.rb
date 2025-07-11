# == Schema Information
#
# Table name: music_memberships
#
#  id         :bigint           not null, primary key
#  joined_on  :date
#  left_on    :date
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  artist_id  :bigint           not null
#  member_id  :bigint           not null
#
# Indexes
#
#  index_music_memberships_on_artist_id             (artist_id)
#  index_music_memberships_on_artist_member_joined  (artist_id,member_id,joined_on) UNIQUE
#  index_music_memberships_on_member_id             (member_id)
#
# Foreign Keys
#
#  fk_rails_...  (artist_id => music_artists.id)
#  fk_rails_...  (member_id => music_artists.id)
#
require "test_helper"

module Music
  class MembershipTest < ActiveSupport::TestCase
    def setup
      @band = music_artists(:pink_floyd)
      @person = music_artists(:roger_waters)
      @membership = music_memberships(:pink_floyd_roger_waters)
    end

    # Validations
    test "should be valid with valid attributes" do
      assert @membership.valid?
    end

    test "should require artist_id" do
      @membership.artist_id = nil
      assert_not @membership.valid?
      assert_includes @membership.errors[:artist_id], "can't be blank"
    end

    test "should require member_id" do
      @membership.member_id = nil
      assert_not @membership.valid?
      assert_includes @membership.errors[:member_id], "can't be blank"
    end

    test "artist must be a band" do
      @membership.artist = music_artists(:david_bowie)  # This is a person
      assert_not @membership.valid?
      assert_includes @membership.errors[:artist], "must be a band"
    end

    test "member must be a person" do
      @membership.member = music_artists(:pink_floyd)  # This is a band
      assert_not @membership.valid?
      assert_includes @membership.errors[:member], "must be a person"
    end

    test "member cannot be the same as artist" do
      @membership.member_id = @membership.artist_id
      assert_not @membership.valid?
      assert_includes @membership.errors[:member], "cannot be the same as the artist"
    end

    test "left_on cannot be before joined_on" do
      @membership.joined_on = Date.new(1985, 1, 1)
      @membership.left_on = Date.new(1980, 1, 1)
      assert_not @membership.valid?
      assert_includes @membership.errors[:left_on], "cannot be before joined_on"
    end

    test "should allow left_on to be after joined_on" do
      @membership.joined_on = Date.new(1980, 1, 1)
      @membership.left_on = Date.new(1985, 1, 1)
      assert @membership.valid?
    end

    test "should allow left_on to be nil" do
      @membership.left_on = nil
      assert @membership.valid?
    end

    # Associations
    test "should belong to artist" do
      assert_respond_to @membership, :artist
      assert_equal @band, @membership.artist
    end

    test "should belong to member" do
      assert_respond_to @membership, :member
      assert_equal @person, @membership.member
    end

    # Scopes
    test "active scope" do
      active_memberships = Music::Membership.active
      assert_includes active_memberships, music_memberships(:pink_floyd_david_gilmour)
      assert_not_includes active_memberships, music_memberships(:pink_floyd_roger_waters)
    end

    test "current scope" do
      current_memberships = Music::Membership.current
      assert_includes current_memberships, music_memberships(:pink_floyd_david_gilmour)
      assert_not_includes current_memberships, music_memberships(:pink_floyd_roger_waters)
    end

    test "former scope" do
      former_memberships = Music::Membership.former
      assert_includes former_memberships, music_memberships(:pink_floyd_roger_waters)
      assert_not_includes former_memberships, music_memberships(:pink_floyd_david_gilmour)
    end
  end
end
