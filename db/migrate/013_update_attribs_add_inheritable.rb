class UpdateAttribsAddInheritable < ActiveRecord::Migration
  def self.up
    add_column :attribs, :inheritable, :boolean, :null => false, :default => false
  end

  def self.down
    remove_column :attribs, :inheritable
  end
end
