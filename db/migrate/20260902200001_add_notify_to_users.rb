# Who hears from the desk (alerts, briefs, pushes; never the sign-in link): on for the approver, off for
# anyone else until it is turned on by hand, so the second reader is not mailed while the kinks are worked out.
class AddNotifyToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :notify, :boolean, null: false, default: false
    execute "UPDATE users SET notify = approver"
  end

  def down = remove_column(:users, :notify)
end
