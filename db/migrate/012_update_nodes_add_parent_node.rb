class UpdateNodesAddParentNode < ActiveRecord::Migration
  def self.up
    add_column :nodes, :node_id, :integer, :null => true
  end

  def self.down
    remove_column :nodes, :node_id
  end
end
