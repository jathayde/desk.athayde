class AddRevokedAtToSchwabTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :schwab_tokens, :revoked_at, :datetime
    add_index :schwab_tokens, [ :issued_at, :id ], order: { issued_at: :desc, id: :desc }
  end
end
