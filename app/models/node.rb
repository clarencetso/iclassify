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

class Node < ActiveRecord::Base
  
  include PasswordEncryption
  
  UUID_REGEX = /^[[:xdigit:]]{8}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{12}$/
  
  attr_accessor :password
  attr_accessor :skip_solr
  attr_accessor :from_user
  
  has_many :attribs, :dependent => :destroy
  has_and_belongs_to_many :tags
  has_many :nodes, :dependent => :nullify
  belongs_to :node, :dependent => :nullify
  
  validates_presence_of   :password, :if => :password_required?
  validates_presence_of   :uuid
  validates_uniqueness_of :uuid
  
  validates_format_of :uuid,
                      :with    => UUID_REGEX,
                      :message => "Must be a valid UUID"

  before_save :check_for_circular_dependencies
  before_save :encrypt_password
  before_save :update_quarantined
  
  # acts_as_ferret(:fields => [ :uuid, :notes, :description, :tag ], :remote =>  true )
  
  acts_as_solr(:fields => [ {:uuid => :text}, {:notes => :text}, {:description => :text}, {:tag => :text} ], 
               :auto_commit => true)


  def check_for_circular_dependencies
    node = self
    count = 0
    parent = node.node
    while parent != nil
      count = count + 1
      if count > 10
        return
      end
      if parent.id == self.id
        return false
      end
      parent = parent.node
    end
  end
  
  def self.authenticate(username, password)
    node = find_by_uuid(username) # need to get the salt
    node && node.authenticated?(password) ? node : nil
  end
  
  def self.find_raw_by_solr(query, options={})
    if options.has_key?(:field_list)
      unless options[:field_list].kind_of?(Array)
        v = options[:field_list]
        options[:field_list] = [ v ]
      end
    else
      options[:field_list] = Array.new
    end
    options[:field_list] << "uuid"
    options[:field_list] << "description"
    options[:field_list] << "notes"
    options[:field_list] << "tag"
    data = parse_query(query, options)
    results = StubNode.from_solr_query(data)
  end
        
  def self.find_record_by_solr(q)
    ids = find_id_by_solr(q, :limit => :all)
    if ids.total > 0
      find(:all, 
           :conditions => "nodes.id IN (#{ids.docs.join(', ')})",
           :order => 'description',
           :include => [ :tags, :attribs ])
    else
      logger.debug("Returning nothing")
      Array.new
    end
  end
  
  # saves to the Solr index
  def solr_save
    if self.skip_solr == true
      logger.debug("Skipping solr_save")
    else
      if self.quarantined == false 
        return true unless configuration[:if] 
        if evaluate_condition(configuration[:if], self) 
          logger.debug "solr_save: #{self.class.name} : #{record_id(self)}"
          this_doc = to_solr_doc
          field_type = configuration[:facets] && configuration[:facets].include?(field) ? :facet : :text
          field_boost= solr_configuration[:default_boost]
          suffix = get_solr_field_type(field_type)
          attribs(:include => :avalues).each do |attrib|
            if attrib.name != "id"
              attrib.avalues.collect { |av| av.value }.each do |v|
                v = set_value_if_nil(suffix) if v.to_s == ""
                logger.debug("adding field #{attrib.name}_#{suffix}: #{v.to_s}")
                field = Solr::Field.new("#{attrib.name}_#{suffix}" => ERB::Util.html_escape(v.to_s))
                this_doc << field 
              end
            end
          end
          logger.debug(this_doc.to_xml)
          solr_add(this_doc)
          solr_commit if configuration[:auto_commit]
          true
        else
          solr_destroy
        end
      end
    end
  end
    
  def tag
    tags.collect { |t| t.name }
  end
  
  def attrib
    resultset = Array.new
    attribs.each do |attrib|
      attrib.avalues.each do |av|
        resultset << "#{attrib.name} #{av.value}"
      end
    end
    resultset
  end
  
  def self.find_by_unique(unique)
    node = nil
    node_unique_field = nil
    case unique
    when /^[[:xdigit:]]{8}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{4}[:-][[:xdigit:]]{12}$/
      node = find_by_uuid(unique)
      node_unique_field = node.uuid if node
    when /^\d+$/
      node = find_by_id(unique)
      node_unique_field = node.id if node
    else
      node = find_by_description(unique)
      logger.info node.to_yaml
      node_unique_field = node.description if node
    end
    return node, node_unique_field
  end

  def get_ancestor_attributes(include_origin=false)
      ancestor_nodes = []
      full_node = Node.find(self.id)
      ancestor_node = full_node.node
      while (ancestor_node != nil and ancestor_node != full_node)
        ancestor_nodes << ancestor_node
        ancestor_node = ancestor_node.node
      end

      attribs = []
      for i in (0..ancestor_nodes.length-1).to_a.reverse
        ancestor_nodes[i].attribs.each do |attrib|
          if attrib.inheritable
            attrib_values = []
            attrib.avalues.each do |avalue|
              attrib_values << avalue.value
            end
            #TODO check for existing attribute name to do subclass overrides
            if include_origin == true
              attribs << { :name => attrib.name, :values => attrib_values, :origin => ancestor_nodes[i] }
            else
              attribs << { :name => attrib.name, :values => attrib_values }
            end
          end
        end
      end
      return attribs
  end

  def get_ancestor_tags(include_origin=false)
      ancestor_nodes = []
      full_node = Node.find(self.id)
      ancestor_node = full_node.node
      while (ancestor_node != nil and ancestor_node != full_node)
        ancestor_nodes << ancestor_node
        ancestor_node = ancestor_node.node
      end

      tags = []
      for i in (0..ancestor_nodes.length-1).to_a.reverse
        if ancestor_nodes[i].tags.length > 0
          if include_origin == true
            tags = tags + ancestor_nodes[i].tags.collect {|x| {:name => x.name, :origin => ancestor_nodes[i]}}
          else
            tags = tags + ancestor_nodes[i].tags.collect {|x| {:name => x.name}}
          end
        end
      end
      return tags
  end

  def get_descendant_leaves(is_root=true)
    total_leaves = []
    if self.nodes.length == 0 and !is_root
      return [self]
    end
    self.nodes.each do |descendant|
      total_leaves = total_leaves + descendant.get_descendant_leaves(false)
    end
    return total_leaves
  end

  def self.find_all_inner_nodes()
    inner_node_ids = Node.find(:all, :select => "DISTINCT(node_id)", :conditions => "node_id IS NOT NULL").collect {|x| x.node_id }
    return Node.find(:all, :conditions => "id IN (#{inner_node_ids.join(',')})" )
  end
  
  def self.bulk_tag(node_hash, tags, from_user=false)
    node_hash.each do |node_id, value|
      node = find(node_id.to_i)
      node.from_user = true if from_user
      node.tags = tags
      node.save
    end
  end
  
  # Tages an array of tag objects, and updates this node with them.
  # Checks to make sure that a tag isn't applied twice.
  def update_tags(tag_list)
    tag_list.each do |tag|
      begin
        tags.find(tag.id)
      rescue
        tags << tag
      end
    end
    self.save
  end
  
  def save_with_tags_and_attribs(tag_array=nil, attrib_array=nil)
    if tag_array
      Tag.create_missing_tags(tag_array).each { |t| tags << t }
    end
    if attrib_array
      Attrib.create_missing_attribs(self, attrib_array).each { |a| attribs << a }
    end
    self.save
  end
  
  def update_with_tags_and_attribs(params, tag_array=nil, attrib_array=nil)
    self.update_attributes(params)
    if tag_array
      tags.each do |tag|
        tags.delete(tag) unless tag_array.include?(tag.name)
      end
      self.tags = Tag.create_missing_tags(tag_array)
    end
    if attrib_array
      attribs(:include => :avalues).each do |attrib|
        attribs.delete(attrib) unless attrib_array.include?({'name' => attrib.name })
      end
      self.attribs = Attrib.create_missing_attribs(self, attrib_array, { :delete => true })
    end
    self.save
  end
  
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{uuid}--") if new_record?
    self.crypted_password = encrypt(password)
  end
  
  # Serializes all the nodes in the database                
  def self.rest_serialize_all
    rest_array = Array.new
    nodes_all = find(:all, :order => :id)
    nodes_all.each do |node|
      rest_array << node.rest_serialize
    end
    rest_array
  end
  
  # Serializes this node
  def rest_serialize
    rest_hash = Hash.new
    rest_hash[:id] = id
    rest_hash[:description] = description
    rest_hash[:notes] = notes
    rest_hash[:uuid] = uuid
    rest_hash[:tags] = Array.new
    tags.each do |tag|
      rest_hash[:tags] << { :id => tag.id, :name => tag.name }
    end
    rest_hash[:attribs] = Array.new
    attribs.each do |attrib|
      ahash = {
        :id => attrib.id,
        :name => attrib.name
      }
      ahash[:values] = attrib.avalues.collect{ |av| av.value }
      rest_hash[:attribs] << ahash
    end
    rest_hash
  end
  
  def set_random_password(len)
    chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
    newpass = ""
    1.upto(len) { |i| newpass << chars[rand(chars.size-1)] }
    self.password = newpass
  end
  
  protected
    def update_quarantined
      if from_user == true && quarantined == true
        logger.debug("Turning off quarantine!")
        self.quarantined = false
        self.save
      else
        logger.debug("Keeping node in quarantine")
      end
    end
  
end
