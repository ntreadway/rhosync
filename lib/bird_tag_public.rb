class BirdTagPublic < SourceAdapter

    include RestAPIHelpers

    def initialize(source,credential)
      super(source,credential)
    end

    def query
      uri = URI.parse(@source.url)
      res = Net::HTTP.start(uri.host, uri.port) {|http|
        http.get("/statuses/public_timeline.xml")
      }
      xml_data = XmlSimple.xml_in(res.body);
      @result = xml_data["status"]
    end

    def sync
      @result.each do |item|
        item_id = item["id"].first.to_i
        iterate_keys(:item => item, :item_id => item_id)
      end
    end

  private
    def iterate_keys(option)
      item = option[:item]
      item_id = option[:item_id]
      prefix = option[:prefix] || ""

      # item.keys => ["user", "favorited", "truncated"...]
      item.keys.each do |key|
        value = item[key] ? item[key][0] : ""
        if value.kind_of?(Hash) && value != {}
          # eg. :user => {:url => 'foo} becomes user_url
          iterate_keys(:prefix => (prefix + underline(key) + "_"), :item => value, :item_id => item_id)
        else
          # This method is from rest_api_helper
          add_triple(@source.id, item_id, prefix + underline(key), value, @source.current_user.id)
        end
      end
    end

    def underline(key)
      key.gsub('-','_')
    end
  end
