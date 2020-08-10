class CampaignList
  # FIXME: This should not be an actor
  include Celluloid

  def initialize
    @campaigns = {}
  end

  def add_campaign(campaign)
    @campaigns[campaign.ref] = campaign
  end

  def remove_campaign(campaign)
    @campaigns.delete campaign.ref
  end

  # def halt_campaign(campaign_ref)
  #     begin
  #       campaign = get_campaign(campaign_ref)
  #       campaign.fire_events! 'halt'
  #     rescue StateMachine::InvalidParallelTransition
  #       logger.warn "API: Failed to transition the campaign from #{campaign.status} to halt"
  #     end
  # end

  # def stop_campaign(campaign_ref)
  #     begin
  #       campaign = get_campaign(campaign_ref)
  #       campaign.fire_events! 'stop'
  #     rescue StateMachine::InvalidParallelTransition
  #       logger.warn "API: Failed to transition the campaign from #{campaign.status} to stop"
  #     end
  # end

  def campaigns
    @campaigns.clone
  end

  def get_campaign(campaign_ref)
    @campaigns[campaign_ref]
  end

  def get_campaign_by_number(number)
    _, campaign = @campaigns.detect{ |k, v| v.settings[:outbound_call_id] == number }
    campaign
  end
end

class ApiManager
  include Celluloid
  include Singleton

  def initialize
    config = Adhearsion.config[:api_manager]
    params = config.to_hash.select { |k,v| !v.nil? }

    unless params[:uri].nil? || params[:uri].empty?
      redis_uri = URI.parse params[:uri]
      params[:user] = redis_uri.user
      params[:password] = redis_uri.password
      params[:host] = redis_uri.host
      params[:port] = redis_uri.port || params[:port]
      params.delete :uri
    end

    @redis = Redis.new params
    @redis.del 'enigma:api'
    
    self.async.api_request_handler
  end

  def api_request_handler
    logger.info "API manager ready"

    loop do
      begin
        logger.debug "Waiting on [enigma:api] for some requests."

        _, request = @redis.blpop('enigma:api', 0)
        request = JSON.parse(request)

        # Request looks like: {type: agent, payload: {json string}}
        type = request.delete 'type'
        data = request.delete 'payload'

        logger.debug "Received API #{type} request: #{data.inspect}"

        case type.to_sym
        when :queue_update
          handle_call_loop_update(data)
        when :campaign
          handle_campaign_request(data)
        when :agent
          handle_agent_request(data)
        end

      rescue Redis::BaseConnectionError => error
        logger.warn "Exception in API Manager: #{error.message}, retrying in 1s"
        logger.warn "Exception trace: #{error.backtrace.join "\n"}"
        sleep 1
        retry
      end
    end
  end

  def handle_call_loop_update(data)
    ref = data['campaign_ref']
    campaign = Celluloid::Actor[:active_campaign_list].get_campaign ref

    if campaign && campaign.call_loop
      logger.debug 'Updating call queue information'
      campaign.call_loop.update_status data['pending_callees'], data['currently_dialing'], data['dial_preview_list'], data['completed_callees'], data['failed_callees']
    end
  end

  def handle_campaign_request(data)
    ref = data['campaign_ref']
    data['settings'] ||= {}
    new_state = data.delete 'status'
    campaign = Celluloid::Actor[:active_campaign_list].get_campaign ref
    new_campaign = campaign.nil?

    # Only create a new campaign if we are going into a started state. Otherwise no queues should exist
    campaign ||= Campaign.new(ref) if new_state == "start"

    if campaign
      campaign.update data['settings']
      begin
        # Trying to stop the campaign again when it is stopped is causing some issues
        unless (campaign.stopped? && new_state == 'stop')
          campaign.fire_events! new_state
        end
      rescue StateMachine::InvalidParallelTransition
        logger.warn "API: Failed to transition the campaign from #{campaign.status} to #{new_state}"
      end

      Celluloid::Actor[:active_campaign_list].add_campaign campaign if new_campaign
      logger.info "API: Campaign #{ref} updated"
    end
  end

  def handle_agent_request(data)
    ref = data['campaign_ref']
    campaign = Celluloid::Actor[:active_campaign_list].get_campaign ref

    # Try grab the campaign cal queue from our campaign, unless that has crashed and been lost.
    call_queue = campaign.call_queue if campaign
    call_queue ||= ElectricSlide.get_queue(ref)

    # If the campaign doesn't have a call queue then we cannot add an agent
    if call_queue
      ext = data['extension']
      new_state = data['status']

      agent = call_queue.get_agent ext
      unless agent
        agent = Agent.new ext, campaign
        # call_queue.add_agent agent
      end

      agent.update_status new_state

      logger.info "API: Updated/created agent #{ext} with status #{new_state} in the scope of campaign #{ref}"

    else
      logger.debug "API: No active campaign #{ref} exists, agent request has been ignored"
    end
  rescue => e
    # ElectricSlide#get_queue raises RuntimeError if the queue is not found
    logger.warn "#{e.message} when trying to handle an agent request: #{data.inspect}"
  end

  class Plugin < Adhearsion::Plugin
    config :api_manager do
      uri       ''         , :desc => 'URI to the Redis instance. Use this or specify each piece of connection information separately below.'
      username  ''         , :desc => 'valid database username'
      password  nil        , :desc => 'valid database password'
      host      'localhost', :desc => 'host where the database is running'
      port      6379       , :desc => 'port where the database is listening'
      db        0          , :desc => 'The redis DB number to listen to for notifications'
      socket    ''         , :desc => 'path to Unix socket where Redis is listening (Optional; to use, set host and port to nil)'
    end

    run :api_manager do
      CampaignList.supervise_as :active_campaign_list
      ApiManager.supervise_as :api_manager_loop
    end
  end
end
