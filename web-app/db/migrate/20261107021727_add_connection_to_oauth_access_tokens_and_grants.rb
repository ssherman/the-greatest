class AddConnectionToOauthAccessTokensAndGrants < ActiveRecord::Migration[8.1]
  # Both tables are empty when this runs (nothing issues a grant until the
  # authorize endpoint ships), so NOT NULL needs no backfill.
  def change
    add_reference :oauth_access_grants, :connection, null: false, index: true,
      foreign_key: {to_table: :oauth_connections}
    add_reference :oauth_access_tokens, :connection, null: false, index: true,
      foreign_key: {to_table: :oauth_connections}
  end
end
