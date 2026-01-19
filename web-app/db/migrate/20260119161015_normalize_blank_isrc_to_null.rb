class NormalizeBlankIsrcToNull < ActiveRecord::Migration[8.1]
  def up
    Music::Song.where(isrc: "").update_all(isrc: nil)
  end

  def down
    # No-op: we can't know which NULLs were originally empty strings
  end
end
