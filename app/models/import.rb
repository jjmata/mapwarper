class Import < ActiveRecord::Base
  has_many :maps
  
  belongs_to :user, :class_name => "User"
  validates_presence_of :category
  validates_presence_of :uploader_user_id
  validate :custom_validate
  
  acts_as_enum :status, [:ready, :running, :finished, :failed]

  after_initialize :default_values
  
  def default_values
    self.status ||= :ready
  end
  
  def prepare_run
    self.update_attribute(:status, :running)
  end
  
  def finish_import
    self.status = :finished
    self.finished_at = Time.now
    self.save
    create_layer
    logger.info "Finished import #{Time.now}"
  end
  
  def import!(options={:async => false})
    async = options[:async] 
    
    if valid? && count > 0
      prepare_run unless async
      log_info "Stared import #{Time.now}"
      begin
        import_maps
        finish_import
      rescue => e
        log_error "Error with import #{e.inspect}"
        
        self.status = :failed
        self.save
      end
      
    end
    
    self.status
  end
  
  
  def import_maps
    site = 'https://commons.wikimedia.org'
    #site = "http://commons.wikimedia.beta.wmflabs.org"
    category_members = []

    cmlimit = 500 # user max = 500 and bots can get 5000 (for users with the apihighlimits)
    uri = "#{site}/w/api.php?action=query&list=categorymembers&cmtype=file&continue=&cmtitle=#{category}&format=json&cmlimit=#{cmlimit}"
    puts uri.inspect

    url = URI.parse(URI.encode(uri))

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    req = Net::HTTP::Get.new(URI.encode(uri))
    req.add_field('User-Agent', 'WikiMaps Warper (Import Maps from Category) Script by Chippyy chippy2005@gmail.com')

    resp = http.request(req)
    body = JSON.parse(resp.body)

    category_members = body['query']['categorymembers']

    until body['continue'].nil?
      url = uri + '&cmcontinue=' + body['continue']['cmcontinue']
      req = Net::HTTP::Get.new(URI.encode(url))
      req.add_field('User-Agent', 'WikiMaps Warper (Import Maps from Category) Script by Chippyy chippy2005@gmail.com')
      resp = http.request(req)
      body = JSON.parse(resp.body)

      category_members += body['query']['categorymembers']
     end

    # puts category_members.size
    category_members.each do |member|
      member_pageid = member["pageid"]
      url = URI.encode("#{site}/w/api.php?action=query&prop=imageinfo&iiprop=url&format=json&pageids=#{member_pageid}")
      req = Net::HTTP::Get.new(URI.encode(url))
      req.add_field('User-Agent', 'WikiMaps Warper (Import Maps from Category) Script by Chippyy chippy2005@gmail.com')
      resp = http.request(req)
      body = JSON.parse(resp.body)

      page_id = body['query']['pages'].keys.first
      image_url =   body['query']['pages'][page_id]['imageinfo'][0]['url']
      image_title = body['query']['pages'][page_id]['title']
      description = 'From: ' + body['query']['pages'][page_id]['imageinfo'][0]['descriptionurl']
      source_uri = body['query']['pages'][page_id]['imageinfo'][0]['descriptionurl']
      unique_id = File.basename(body['query']['pages'][page_id]['imageinfo'][0]['url'])

      next if Map.exists?(page_id: page_id)

      map = {
        title: image_title,
        unique_id: unique_id,
        public: true,
        map_type: 'is_map',
        description: description,
        source_uri: source_uri,
        upload_url: image_url,
        page_id: page_id,
        image_url: image_url,
        status: :unloaded
      }

      map = Map.new(map)
      
      map.import_id = self.id
      map.owner = self.user
      map.users << self.user
      
      map.save
      
      log_info "Saved new Map: " + map.inspect
    end

      # {"pageid"=>40820573, "ns"=>6, "title"=>"File:Senate Atlas, 1870–1907. Sheet XVI 12 Rauma.jpg"}
      # query API for map
      # build map
      # save map as unloaded
  end


  def create_layer
    log_info "Creating new layer and assigning maps to it"
    if Layer.exists?(name: self.category)
      log_error "Layer exists with the same name #{self.category}! Skipping creating new layer."
    else
      layer = Layer.new(name: self.category, user: self.user, source_uri: "https://commons.wikimedia.org/wiki/#{self.category}")
      layer.maps = maps
      layer.save
    end
    
    log_info "Finished saving new layer"
  end
  
  #
  # Calls the wikimedia Commons and returns the File Count within the category
  # category in format "Category:1681 maps"
  #
  def self.count(category)
    category = URI.encode(category)
    url = "https://commons.wikimedia.org/w/api.php?action=query&prop=categoryinfo&format=json&titles=#{category}"
   
    #combined = /w/api.php?action=query&list=categorymembers&prop=categoryinfo&format=json&cmtitle=Category%3A1681_maps&titles=Category%3A1681_maps
    log_info "calling #{url}"
    data = URI.parse(url).read
    body = ActiveSupport::JSON.decode(data)
    log_info body.inspect
    #{"batchcomplete"=>"", "query"=>{"pages"=>{"88441"=>{"pageid"=>88441, "ns"=>14, "title"=>"Category:Maps of Finland", "categoryinfo"=>{"size"=>610, "pages"=>2, "files"=>581, "subcats"=>27}}}}}
   
    file_count = 0
    if body["query"]["pages"].keys.first != "-1"
      page_id = body["query"]["pages"].keys.first
      file_count = body["query"]["pages"][page_id]["categoryinfo"]["files"]
    end
    
    file_count
  end
  
  def count
    Import.count(self.category)
  end

  protected
  
  def custom_validate
    errors.add(:layer_id, "does not exist, or has not been specified properly") unless Layer.exists?(layer_id) || layer_id == nil || layer_id == -99
    errors.add(:uploader_user_id, "does not exist") if !User.exists?(uploader_user_id)
    errors.add(:category, "must begin with 'Category:'") unless category.starts_with?("Category:")
  end

  def self.log_info(msg)
    puts msg  if defined? Rake
    logger.info msg
  end
  
  def self.log_error(msg)
    puts msg  if defined? Rake
    logger.error msg
  end
  
  def log_info(msg)
    Import.log_info(msg)
  end
  
  def log_error(msg)
    Import.log_error(msg)
  end

end
