# Expectancy in R per trade is avg_r by identity; one fact, one column (Setup#expectancy reads avg_r).
class DropSetupsExpectancy < ActiveRecord::Migration[8.1]
  def change
    remove_column :setups, :expectancy, :decimal, precision: 12, scale: 4
  end
end
