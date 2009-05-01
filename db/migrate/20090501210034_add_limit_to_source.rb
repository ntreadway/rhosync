class AddLimitToSource < ActiveRecord::Migration
  def self.up
    add_column :sources, :limit, :string
  end

  def self.down
    remove_column :sources, :limit
  end
end
