class Import < ActiveRecord::Base
  has_many :maps
  belongs_to :layer
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
  
  def finish_import(options)
    self.status = :finished
    self.finished_at = Time.now
    self.save
    save_maps_to_layer unless self.maps.empty? || self.save_layer == false
    logger.info "Finished import #{Time.now}"
  end
  
  def import!(options={})
    options = {:async => false}.merge(options)
    
    async = options[:async]
    if valid? && file_count > 0
      prepare_run unless async
      log_info "Stared import #{Time.now}"
      begin
        import_maps
        finish_import(options)
      rescue => e
        log_error "Error with import #{e.inspect}"
        log_error e.backtrace
        
        self.status = :failed
        self.save
      end
      
    end
    
    self.status
  end
  
  
  def import_maps
    site = APP_CONFIG["omniauth_mediawiki_site"]
    user_agent = "#{APP_CONFIG['site']} (Import Maps from Category) (https://commons.wikimedia.org/wiki/Commons:Wikimaps)"
    category_members = []

    cmlimit = 500 # user max = 500 and bots can get 5000 (for users with the apihighlimits)
    uri = "#{site}/w/api.php?action=query&list=categorymembers&cmtype=file&continue=&cmtitle=#{category}&format=json&cmlimit=#{cmlimit}"
    puts uri.inspect

    url = URI.parse(URI.encode(uri))

    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true if url.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if url.scheme == "https"

    req = Net::HTTP::Get.new(URI.encode(uri))
    req.add_field('User-Agent', user_agent)

    resp = http.request(req)
    body = JSON.parse(resp.body)

    category_members = body['query']['categorymembers']

    until body['continue'].nil?
      url = uri + '&cmcontinue=' + body['continue']['cmcontinue']
      req = Net::HTTP::Get.new(URI.encode(url))
      req.add_field('User-Agent', user_agent)
      resp = http.request(req)
      body = JSON.parse(resp.body)

      category_members += body['query']['categorymembers']
     end

    # puts category_members.size
    category_members.each do |member|
      member_pageid = member["pageid"]
      url = URI.encode("#{site}/w/api.php?action=query&prop=imageinfo&iiprop=url&format=json&pageids=#{member_pageid}")
      req = Net::HTTP::Get.new(URI.encode(url))
      req.add_field('User-Agent', user_agent)
      resp = http.request(req)
      body = JSON.parse(resp.body)

      page_id = body['query']['pages'].keys.first
      image_url =   body['query']['pages'][page_id]['imageinfo'][0]['url']
      image_title = body['query']['pages'][page_id]['title']
      description = 'From: ' + body['query']['pages'][page_id]['imageinfo'][0]['descriptionurl']
      source_uri = body['query']['pages'][page_id]['imageinfo'][0]['descriptionurl']
      unique_id = File.basename(body['query']['pages'][page_id]['imageinfo'][0]['url'])

      if Map.exists?(page_id: page_id)
        map = Map.find_by_page_id(page_id)
        map.import_id = self.id
        map.save
      else

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
    end


  end

  def save_maps_to_layer
    log_info "Saving maps to layer"
    if Layer.exists?(name: self.category) 
      existing_layer = Layer.find_by_name(self.category)
      log_info "Appending maps to  existing layer #{existing_layer.inspect}"
      maps_to_add = self.maps.select{ |map| !existing_layer.maps.include?(map)}
      existing_layer.maps << maps_to_add
      self.layer = existing_layer
      save
    else
  
      new_layer = Layer.new(name: self.category, user: self.user, source_uri: "https://commons.wikimedia.org/wiki/#{self.category}")
      new_layer.maps << self.maps
      new_layer.save
      log_info "Saving maps to new Layer #{new_layer.inspect}"
      self.layer = new_layer
      save
    end
    
    log_info "Finished saving new layer"
  end
  
  #
  # Calls the wikimedia Commons and returns the File Count within the category
  # category in format "Category:1681 maps"
  #
  def self.file_count(category)
    category = URI.encode(category)
    site = APP_CONFIG["omniauth_mediawiki_site"]
    url = "#{site}/w/api.php?action=query&prop=categoryinfo&format=json&titles=#{category}"
   
    #combined = /w/api.php?action=query&list=categorymembers&prop=categoryinfo&format=json&cmtitle=Category%3A1681_maps&titles=Category%3A1681_maps
    log_info "calling #{url}"
    data = URI.parse(url).read
    body = ActiveSupport::JSON.decode(data)
   
    file_count = 0
    if body["query"]["pages"].keys.first != "-1"
      page_id = body["query"]["pages"].keys.first
      file_count = body["query"]["pages"][page_id]["categoryinfo"]["files"]
    end
    
    file_count
  end
  
  def file_count
    Import.file_count(self.category)
  end
  
  def has_map_template?
    site = APP_CONFIG["omniauth_mediawiki_site"]
    user_agent = "#{APP_CONFIG['site']} (Import Maps from Category) (https://commons.wikimedia.org/wiki/Commons:Wikimaps)"
    category_members = []

    cmlimit = 2
    uri = "#{site}/w/api.php?action=query&list=categorymembers&cmtype=file&continue=&cmtitle=#{category}&format=json&cmlimit=#{cmlimit}"

    url = URI.parse(URI.encode(uri))
    log_info "Calling #{url}"
    http = Net::HTTP.new(url.host, url.port)
    http.use_ssl = true if url.scheme == "https"
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if url.scheme == "https"
    
    begin
      req = Net::HTTP::Get.new(URI.encode(uri))
      req.add_field('User-Agent', user_agent)
      resp = http.request(req)
      body = JSON.parse(resp.body)
    rescue JSON::ParserError => e
      logger.error "JSON::ParserError with OAuth Get from wiki api"
      logger.error e.inspect
      return false
    rescue => e
      logger.error "Error with OAuth Get from wiki api"
      logger.error e.inspect
      return false
    end
    
    #auth Error
    if body["error"]
      logger.error "Response body returned error"
      logger.error body["error"].inspect
      return false
    end

    category_members = body['query']['categorymembers']

    member = category_members.first
    member_pageid = member["pageid"]
    url = "#{site}/w/api.php?action=query&prop=revisions&rvprop=content&format=json&pageids=#{member_pageid}"
    log_info "Calling #{url}"
    req = Net::HTTP::Get.new(URI.encode(url))
    req.add_field('User-Agent', user_agent)
    resp = http.request(req)
    body = JSON.parse(resp.body)
    
    pageid = body["query"]["pages"].keys.first
    return false if body["query"]["pages"][pageid]["missing"]
    
    revision = body["query"]["pages"][pageid]["revisions"].first 
    wikitext = revision["*"]
    
    map_match = /\{{2}\s*(Map|Template:map)(.*)}}/mi.match(wikitext)
    
    if map_match
      return true
    else
      return false
    end
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
