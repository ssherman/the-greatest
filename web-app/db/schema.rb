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

ActiveRecord::Schema[8.0].define(version: 2025_07_06_224507) do
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

  create_table "list_items", force: :cascade do |t|
    t.bigint "list_id", null: false
    t.string "listable_type", null: false
    t.bigint "listable_id", null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id", "listable_type", "listable_id"], name: "index_list_items_on_list_and_listable_unique", unique: true
    t.index ["list_id", "position"], name: "index_list_items_on_list_id_and_position"
    t.index ["list_id"], name: "index_list_items_on_list_id"
    t.index ["listable_type", "listable_id"], name: "index_list_items_on_listable"
  end

  create_table "lists", force: :cascade do |t|
    t.string "type", null: false
    t.string "name", null: false
    t.text "description"
    t.string "source"
    t.string "url"
    t.integer "status", default: 0, null: false
    t.integer "estimated_quality", default: 0, null: false
    t.boolean "high_quality_source"
    t.boolean "category_specific"
    t.boolean "location_specific"
    t.integer "year_published"
    t.boolean "yearly_award"
    t.integer "number_of_voters"
    t.boolean "voter_count_unknown"
    t.boolean "voter_names_unknown"
    t.text "formatted_text"
    t.text "raw_html"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "submitted_by_id"
    t.index ["submitted_by_id"], name: "index_lists_on_submitted_by_id"
  end

  create_table "movies_credits", force: :cascade do |t|
    t.bigint "person_id", null: false
    t.string "creditable_type", null: false
    t.bigint "creditable_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "position"
    t.string "character_name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_movies_credits_on_creditable_type_and_creditable_id"
    t.index ["person_id", "role"], name: "index_movies_credits_on_person_id_and_role"
    t.index ["person_id"], name: "index_movies_credits_on_person_id"
  end

  create_table "movies_movies", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.integer "release_year"
    t.integer "runtime_minutes"
    t.integer "rating"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["rating"], name: "index_movies_movies_on_rating"
    t.index ["release_year"], name: "index_movies_movies_on_release_year"
    t.index ["slug"], name: "index_movies_movies_on_slug", unique: true
  end

  create_table "movies_people", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.text "description"
    t.date "born_on"
    t.date "died_on"
    t.string "country", limit: 2
    t.integer "gender"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["gender"], name: "index_movies_people_on_gender"
    t.index ["slug"], name: "index_movies_people_on_slug", unique: true
  end

  create_table "movies_releases", force: :cascade do |t|
    t.bigint "movie_id", null: false
    t.string "release_name"
    t.integer "release_format", default: 0, null: false
    t.integer "runtime_minutes"
    t.date "release_date"
    t.jsonb "metadata"
    t.boolean "is_primary", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["is_primary"], name: "index_movies_releases_on_is_primary"
    t.index ["movie_id", "release_name", "release_format"], name: "index_movies_releases_on_movie_and_name_and_format", unique: true
    t.index ["movie_id"], name: "index_movies_releases_on_movie_id"
    t.index ["release_date"], name: "index_movies_releases_on_release_date"
    t.index ["release_format"], name: "index_movies_releases_on_release_format"
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

  create_table "music_credits", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.string "creditable_type", null: false
    t.bigint "creditable_id", null: false
    t.integer "role", default: 0, null: false
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "role"], name: "index_music_credits_on_artist_id_and_role"
    t.index ["artist_id"], name: "index_music_credits_on_artist_id"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable"
    t.index ["creditable_type", "creditable_id"], name: "index_music_credits_on_creditable_type_and_creditable_id"
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

  create_table "music_song_relationships", force: :cascade do |t|
    t.bigint "song_id", null: false
    t.bigint "related_song_id", null: false
    t.integer "relation_type", default: 0, null: false
    t.bigint "source_release_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["related_song_id"], name: "index_music_song_relationships_on_related_song_id"
    t.index ["song_id", "related_song_id", "relation_type"], name: "index_music_song_relationships_on_song_related_type", unique: true
    t.index ["song_id"], name: "index_music_song_relationships_on_song_id"
    t.index ["source_release_id"], name: "index_music_song_relationships_on_source_release_id"
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

  create_table "users", force: :cascade do |t|
    t.string "auth_uid"
    t.jsonb "auth_data"
    t.string "email"
    t.string "display_name"
    t.string "name"
    t.string "photo_url"
    t.string "original_signup_domain"
    t.integer "role", default: 0, null: false
    t.integer "external_provider"
    t.boolean "email_verified", default: false, null: false
    t.datetime "last_sign_in_at"
    t.integer "sign_in_count"
    t.text "provider_data"
    t.string "stripe_customer_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["auth_uid"], name: "index_users_on_auth_uid"
    t.index ["external_provider"], name: "index_users_on_external_provider"
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id"
  end

  add_foreign_key "list_items", "lists"
  add_foreign_key "lists", "users", column: "submitted_by_id"
  add_foreign_key "movies_credits", "movies_people", column: "person_id"
  add_foreign_key "movies_releases", "movies_movies", column: "movie_id"
  add_foreign_key "music_albums", "music_artists", column: "primary_artist_id"
  add_foreign_key "music_credits", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "artist_id"
  add_foreign_key "music_memberships", "music_artists", column: "member_id"
  add_foreign_key "music_releases", "music_albums", column: "album_id"
  add_foreign_key "music_song_relationships", "music_releases", column: "source_release_id"
  add_foreign_key "music_song_relationships", "music_songs", column: "related_song_id"
  add_foreign_key "music_song_relationships", "music_songs", column: "song_id"
  add_foreign_key "music_tracks", "music_releases", column: "release_id"
  add_foreign_key "music_tracks", "music_songs", column: "song_id"
end
