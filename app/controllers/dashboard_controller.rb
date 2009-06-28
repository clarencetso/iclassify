#  iClassify - A node classification service. 
#  Copyright (C) 2007 HJK Solutions and Adam Jacob (<adam@hjksolutions.com>)
# 
#  This program is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
# 
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
# 
#  You should have received a copy of the GNU General Public License along
#  with this program; if not, write to the Free Software Foundation, Inc.,
#  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

class DashboardController < ApplicationController
  
  include AuthorizedAsUser
  
  before_filter :login_required
  before_filter :can_write, :except => [ "index" ]
  
  
  # GET /
  # GET /dashboard
  # GET /dashboard.xml
  def index
    @unclassified_nodes = get_unclassified_nodes()
    @tags = Tag.find(:all)
    @tags ||= Array.new
    @all_nodes = Node.find(:all)
  end

  def tree
    @unclassified_nodes = get_unclassified_nodes()
    @tags = Tag.find(:all)
    @tags ||= Array.new
    @nodes = Node.find_all_inner_nodes()
    @root_nodes = Node.find(:all, :conditions => { :node_id => nil })
    
  end
  
  def bulk_tag
    if params[:tag_nodes] && params[:tag_list]
      tag_nodes = params[:tag_nodes]
      tags = Tag.create_missing_tags(params[:tag_list].split(" "))
      Node.bulk_tag(tag_nodes, tags, true)
      flash[:bulk_tags_notice] = "Nodes have been updated."
      redirect_to(url_for(:controller => "dashboard", :action => "index")) unless request.xhr?
      @tags = Tag.find(:all)
      @tags ||= Array.new
      @nodes = Node.find_record_by_solr(params[:search_query])
      if params[:search_query] == "tag:unclassified"
        @partial_to_render = "search/bulk_tag"
        @heading = "Unclassified Nodes"
      else
        @partial_to_render = "search/bulk_tag"
        @heading = "Search Results"
      end
    else
      flash[:bulk_tags_notice] = "You must select some nodes to tag!"
      redirect_to(url_for(:controller => "dashboard", :action => "index")) unless request.xhr?
      @tags = Tag.find(:all)
      @tags ||= Array.new
      @nodes = Node.find_record_by_solr(params[:search_query])
      if params[:search_query] == "tag:unclassified"
        @partial_to_render = "search/bulk_tag"
        @heading = "Unclassified Nodes"
      else
        @partial_to_render = "search/bulk_tag"
        @heading = "Search Results"
      end
    end
    render :template => "dashboard/bulk_tag.js.rjs"
  end

  def bulk_change_parent
    if params[:node_parent][:select] == 'text'
      if params[:node_parent_text] == ''
        flash[:bulk_node_parent_notice] = "You must enter a node ID if you select that option."
        redirect_to :action => 'tree' and return
      end
      parent_id = params[:node_parent_text]
    else
      parent_id = params[:node_parent][:select]
    end


    if !params.has_key?(:node_parent_checkboxes)
      flash[:bulk_node_parent_notice] = "You didn't select any nodes to apply the change to!"
      redirect_to :action => 'tree' and return
    end
    selected_nodes = Node.find(:all, :conditions => "id IN (#{params[:node_parent_checkboxes].keys.join(',')})")
    parent_node = Node.find(:first, :conditions => ["id = ?", parent_id.to_i])
    if parent_node == nil
      flash[:bulk_node_parent_notice] = "We couldn't find a node that corresponded to the parent ID '#{parent_id}' that you requested!!"
      redirect_to :action => 'tree' and return
    end
    selected_nodes.each do |selected_node|
      logger.debug(selected_node.description)
      selected_node.node = parent_node
      selected_node.save
    end
    redirect_to :action => 'tree'
  end
  
  private
  
  def get_unclassified_nodes
    uctag = Tag.find_by_name("unclassified", :include => :nodes)
    uctag ? uctag.nodes : Array.new
  end
end
