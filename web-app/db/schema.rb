# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_07_03_053333) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "friendly_id_slugs", force: :cascade do |t|
    t.string "slug", null: false
    t.integer "sluggable_id", null: false
    t.string "sluggable_type", limit: 50
    t.string "scope"
    t.datetime "created_at"
    t.index ["slug", "sluggable_type", "scope"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type_and_scope", unique: true
    t.index ["slug", "sluggable_type"], name: "index_friendly_id_slugs_on_slug_and_sluggable_type"
    t.index ["sluggable_type", "sluggable_id"], name: "index_friendly_id_slugs_on_sluggable_type_and_sluggable_id"
  end

  create_table "music_albums", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.bigint "primary_artist_id", null: false
    t.integer "release_year"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["primary_artist_id"], name: "index_music_albums_on_primary_artist_id"
    t.index ["slug"], name: "index_music_albums_on_slug", unique: true
  end

  create_table "music_artists", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "kind", default: 0, null: false
    t.string "country", limit: 2
    t.date "born_on"
    t.date "died_on"
    t.date "formed_on"
    t.date "disbanded_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_music_artists_on_kind"
    t.index ["slug"], name: "index_music_artists_on_slug", unique: true
  end

  create_table "music_memberships", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.bigint "member_id", null: false
    t.date "joined_on"
    t.date "left_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "member_id", "joined_on"], name: "index_music_memberships_on_artist_member_joined", unique: true
    t.index ["artist_id"], name: "index_music_memberships_on_artist_id"
    t.index ["member_id"], name: "index_music_memberships_on_member_id"
  end

  create_table "music_releases", force: :cascade do |t|
    t.bigint "album_id", null: false
    t.string "release_name"
    t.integer "format", default: 0, null: false
    t.jsonb "metadata"
    t.date "release_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["album_id", "release_name", "format"], name: "index_music_releases_on_album_name_format_unique", unique: true
    t.index ["album_id"], name: "index_music_releases_on_album_id"
  end

  create_table "music_songs", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "duration_secs"
    t.integer "release_year"
    t.string "isrc", limit: 12
    t.text "lyrics"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["isrc"], name: "index_music_songs_on_isrc", unique: true, where: "(isrc IS NOT NULL)"
    t.index ["slug"], name: "index_music_songs_on_slug", unique: true
  end

  create_table "music_tracks", force: :cascade do |t|
    t.bigint "release_id", null: false
    t.bigint "song_id", null: false
    t.integer "medium_number", default: 1, null: false
    t.integer "position", null: false
    t.integer "length_secs"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["release_id", "medium_number", "position"], name: "index_music_tracks_on_release_medium_position", unique: true
    t.index ["release_id"], name: "index_music_tracks_on_release_id"
    t.index ["song_id"], name: "index_music_tracks_on_song_id"
  end

  add_foreign_key "music_albums", "music_artists", column: "primary_artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "member_id"
  add_foreign_key "music_releases", "music_albums", column: "album_id"
  add_foreign_key "music_tracks", "music_releases", column: "release_id"
  add_foreign_key "music_tracks", "music_songs", column: "song_id"
end
