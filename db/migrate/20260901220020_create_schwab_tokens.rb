class CreateSchwabTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :schwab_tokens do |t|
      t.text :access_token, null: false
      t.text :refresh_token, null: false
      t.datetime :access_expires_at, null: false
      t.datetime :refresh_expires_at, null: false # issued_at + 7 days; never moved by a refresh
      t.datetime :issued_at, null: false
      t.datetime :last_refreshed_at
      t.text :last_refresh_error
      t.string :scope

      t.timestamps
    end
  end
end
