module SourcesHelper
  
  def slog(e,msg,source_id=self.id,operation=nil,timing=nil)
    begin
      l=SourceLog.new
      l.source_id=source_id
      l.error=e.inspect.to_s if not e.nil?
      l.error||=""
      l.message=msg
      l.operation=operation
      l.timing=timing
      l.save
    rescue Exception=>e
      logger.debug "Failed to save source log message: " + e
    end
  end
  
  def tlog(start,operation,source_id)
    diff=(Time.new-start)
    slog(nil,"Timing: "+diff.to_s+" seconds",source_id,operation,diff)
  end

  # determines if the logged in users is a subscriber of the current app or 
  # admin of the current app
  def check_access(app)
    logger.debug "Checking access for user "+@current_user.login
    matches_login=app.users.select{ |u| u.login==@current_user.login}
    matches_login << app.administrations.select { |a| a.user.login==@current_user.login } # let the administrators of the app in as well
    if !(app.anonymous==1) and (matches_login.nil? or matches_login.size == 0)
      logger.info  "App is not anonymous and user was not found in subscriber list"
      logger.info "User: " + current_user.login + " not allowed access."
      username = current_user.login
      username ||= "unknown"
      result=nil
    end
    result=@current_user
  end
  
  def needs_refresh
    result=nil
    # refresh if there are any updates to come
    # INDEX: SHOULD USE BY_SOURCE_USER_TYPE 
    count_updates = "select count(*) from object_values where update_type!='query' and source_id="+id.to_s
    (count_updates << " and user_id="+ credential.user.id.to_s) if credential# if there is a credential then just do delete and update based upon the records with that credential  
    (result=true) if (ObjectValue.count_by_sql count_updates ) > 0

    # refresh if there is no data
    # INDEX: SHOULD USE BY_SOURCE_USER_TYPE
    count_query_objs="select count(*) from object_values where update_type='query' and source_id="+id.to_s
    (count_query_objs << " and user_id="+ credential.user.id.to_s) if credential# if there is a credential then just do delete and update based upon the records with that credential  
    (result=true) if (ObjectValue.count_by_sql count_query_objs ) <= 0
    
    # refresh is the data is old
    self.pollinterval||=300 # 5 minute default if there's no pollinterval or its a bad value
    if !self.refreshtime or ((Time.new - self.refreshtime)>pollinterval)
      result=true
    end
    result  # return true of false (nil)
  end
  
  # presence or absence of credential determines whether we are using a "per user sandbox" or not
  def clear_pending_records(credential)
    delete_cmd= "(update_type is null) and source_id="+id.to_s
    (delete_cmd << " and user_id="+ credential.user.id.to_s) if credential # if there is a credential then just do delete and update based upon the records with that credential
    begin
      start=Time.new
      ObjectValue.delete_all delete_cmd
      tlog(start,"delete",self.id)
    rescue Exception=>e
      slog(e, "Failed to delete existing records ",self.id)
    end
  end
  
  # presence or absence of credential determines whether we are using a "per user sandbox" or not
  def remove_dupe_pendings(credential)
    pendings_cmd = "select id,pending_id,object,attrib,value from object_values where update_type is null and source_id="+id.to_s
    (pendings_cmd << " and user_id="+ credential.user.id.to_s) if credential# if there is a credential then just do delete and update based upon the records with that credential  
    pendings_cmd << " order by pending_id"
    objs=ObjectValue.find_by_sql pendings_cmd
    prev=nil
    objs.each do |obj|  # remove dupes
      if (prev and (obj.pending_id==prev.pending_id))
        p "Deleting a duplicate: " + obj.pending_id.to_s + "(#{obj.object.to_s},#{obj.attrib},#{obj.value})"
        ObjectValue.delete(prev.id)
      end
      prev=obj
    end
  end
  
  def update_pendings  
    conditions="source_id=#{id}"
    conditions << " and user_id=#{credential.user.id}" if credential
    objs=ObjectValue.find :all, :conditions=>conditions, :order=> :pending_id
    objs.each do |obj|  
      begin
        pending_to_query="update object_values set update_type='query',id=pending_id where id="+obj.id.to_s
        ActiveRecord::Base.connection.execute(pending_to_query)
      rescue Exception => e
        slog(e,"Failed to finalize object value (due to duplicate) for object "+obj.id.to_s,id)
      end
    end   
  end

  # presence or absence of credential determines whether we are using a "per user sandbox" or not
  def finalize_query_records(credential)
    # first delete the existing query records
    ActiveRecord::Base.transaction do
      delete_cmd = "(update_type is not null) and source_id="+id.to_s
      (delete_cmd << " and user_id="+ credential.user.id.to_s) if credential # if there is a credential then just do delete and update based upon the records with that credential
      ObjectValue.delete_all delete_cmd
      remove_dupe_pendings(credential)
=begin
      pending_to_query="update object_values set update_type='query',id=pending_id where update_type is null and source_id="+id.to_s
      (pending_to_query << " and user_id=" + credential.user.id.to_s) if credential
      ActiveRecord::Base.connection.execute(pending_to_query)
=end
      update_pendings
    end
    self.refreshtime=Time.new # timestamp    
  end

  # helper function to come up with the string used for the name_value_list
  # name_value_list =  [ { "name" => "name", "value" => "rhomobile" },
  #                     { "name" => "industry", "value" => "software" } ]
  def make_name_value_list(hash)
    if hash and hash.keys.size>0
      result="["
      hash.keys.each do |x|
        result << ("{'name' => '"+ x +"', 'value' => '" + hash[x] + "'},") if x and x.size>0 and hash[x]
      end
      result=result[0...result.size-1]  # chop off last comma
      result += "]"
    end
  end
    
  def process_update_type(utype)
    start=Time.new  # start timing the operation
    objs=ObjectValue.find_by_sql("select distinct(object) as object,blob_file_name,blob_content_type,blob_file_size from object_values where update_type='"+ utype +"'and source_id="+id.to_s)
    if objs # check that we got some object values back
      objs.each do |x|
        logger.debug "Object returned is: " + x.inspect.to_s
        if x.object  
          objvals=ObjectValue.find_all_by_object_and_update_type(x.object,utype)  # this has all the attribute value pairs now
          attrvalues={}
          attrvalues["id"]=x.object if utype!='create' # setting the ID allows it be an update or delete
          blob_file=x.blob_file_name
          objvals.each do |y|
            attrvalues[y.attrib]=y.value
          end
          # now attrvalues has the attribute values needed for the create,update,delete call
          nvlist=make_name_value_list(attrvalues)
          if source_adapter
            name_value_list=eval(nvlist)
            params="(name_value_list"+ (x.blob_file_name ? ",x.blob)" : ")")
            eval("source_adapter." +utype +params)
          end
        else
          msg="Missing object property on object value: " + x.inspect.to_s
          logger.info msg
        end
      end
    else # got no object values back
      msg "Failed to retrieve object values for " + utype
      slog(nil,msg)
    end
    tlog(start,utype,self.id) # log the time to perform the particular type of operation
  end
  
  def cleanup_update_type(utype)
    objs=ObjectValue.find_by_sql("select distinct(object) as object from object_values where update_type='"+ utype +"'and source_id="+id.to_s)
    objs.each do |x| 
      if x.object
        objvals=ObjectValue.find_all_by_object_and_update_type(x.object,utype)  # this has all the attribute value pairs now
        objvals.each do |y|
          y.destroy
        end
      else
        msg="Missing object property on object value: " + x.inspect.to_s
        p msg
        slog(nil,msg)
      end 
    end   
  end
  
  # grab out all ObjectValues of updatetype="Create" with object named "qparms" 
  # for a specific user (user_id) and source (id)
  # put those together into a hash where each attrib is the key and each value is the value
  # return nil if there are no such objects
  def qparms_from_object(user_id)
    qparms=nil
    attrs=ObjectValue.find_by_sql("select attrib,value from object_values where object='qparms' and update_type='create'and source_id="+id.to_s+" and user_id="+user_id.to_s)
    if attrs
      qparms={}
      attrs.each do |x|
        qparms[x.attrib]=x.value
        x.destroy
      end
    end
    qparms
  end
  
  def setup_client(client_id)
    # setup client & user association if it doesn't exist
    if client_id and client_id != 'client_id'
      @client = Client.find_by_client_id(client_id)
      if @client.nil?
        @client = Client.new
        @client.client_id = client_id
      end
      @client.user ||= current_user
      @client.save
    end
    @client
  end

  
  # creates an object_value list for a given client
  # based on that client's client_map records
  # and the current state of the object_values table
  # since we do a delete_all in rhosync refresh, 
  # only delete and insert are required
  def process_objects_for_client(source,client,token,ack_token,resend_token,p_size=nil,first_request=false)
    
    # default page size of 10000
    page_size = p_size.nil? ? 10000 : p_size.to_i
    last_sync_time = Time.now
    objs_to_return = []
    user_condition="= #{current_user.id}" if current_user and current_user.id
    user_condition ||= "is NULL"
    
    # Setup the join conditions
    object_value_join_conditions = "from object_values ov left join client_maps cm on \
                                    ov.id = cm.object_value_id and \
                                    cm.client_id = '#{client.id}'"
    object_value_conditions = "#{object_value_join_conditions} \
                               where ov.update_type = 'query' and \
                                 ov.source_id = #{source.id} and \
                                 ov.user_id #{user_condition} and \
                                 cm.object_value_id is NULL order by ov.object limit #{page_size}"                  
    object_value_query = "select * #{object_value_conditions}"
    
    # setup fields to insert in client_maps table
    object_insert_query = "select '#{client.id}' as a,id,'insert','#{token}' #{object_value_conditions}"
                    
    # if we're resending the token, quickly return the results (inserts + deletes)
    if resend_token
      logger.debug "[sources_helper] resending token, resend_token: #{resend_token.inspect}"
      objs_to_return = ClientMap.get_delete_objs_by_token_status(client.id)
      client.update_attributes({:updated_at => last_sync_time, :last_sync_token => resend_token})
      objs_to_return.concat( ClientMap.get_insert_objs_by_token_status(object_value_join_conditions,client.id,resend_token) )
    else
      logger.debug "[sources_helper] ack_token: #{ack_token.inspect}, using new token: #{token.inspect}"
      
      # mark acknowledged token so we don't send it again
      ClientMap.mark_objs_by_ack_token(ack_token) if ack_token and ack_token.length > 0
      
      # find delete records
      objs_to_return.concat( ClientMap.get_delete_objs_for_client(token,page_size,client.id) )

      # find + save insert records
      objs_to_insert = ObjectValue.find_by_sql object_value_query
      ClientMap.insert_new_client_maps(object_insert_query)
      objs_to_insert.collect! {|x| x.db_operation = 'insert'; x}

      # Update the last updated time for this client
      # to track the last sync time
      client.update_attribute(:updated_at, last_sync_time)
      objs_to_return.concat(objs_to_insert)
      
      if token and objs_to_return.length > 0
        client.update_attribute(:last_sync_token, token)
      else
        client.update_attribute(:last_sync_token, nil)
      end
    end
    objs_to_return
  end
end