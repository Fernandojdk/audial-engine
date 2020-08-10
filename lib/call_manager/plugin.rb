class CallManager
  include Celluloid
  include Singleton

  def initialize
    config = Adhearsion.config[:call_manager]
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

    self.async.call_queue_handler
  end

  def call_queue_handler
    logger.info "WAITING FOR CALL OPERATIONS"

    begin
    @redis.subscribe("call:management") do |on|
      on.message do |channel, msg|

        params = JSON.parse(msg)

        call = Adhearsion.active_calls.with_tag(params['call_ref'].to_s).try(:first)
        logger.info "Call Manager: Received request for call #{call}: #{params.inspect}"

        if call
          handle_request(call, params)
        end

      end
    end
    rescue Redis::BaseConnectionError => error
      logger.warn "Lost Redis connection: #{error}, retrying in 1s"
      sleep(1)
      retry
    end
  end

  def handle_request(call, params)

    case params['type'].to_sym
    when :disposition
      call_disposition(call, params['disposition'].to_sym)
    when :transfer
      call_transfer(call, params['to'])
    when :play_recording
      call_play_recording(call, params['recording_path'])
    end

  end

# FIXME: Re-add this logic here. Currently the API sets the disposition, would be better for the dialler to always handle this
  def call_disposition(call, disposition)
    # call.set_end_reason(disposition)
    call.try(:hangup)
  rescue Adhearsion::Call::Hangup
  end

  def call_transfer(call, to)
    # Check if agent is in campaign
    # Split agent and callee
    # make agent fall back into their normal controller
    # callee must fall into new agents queue - Need to figure this out
    # Initiate a call to the new agent if one doesn't exist
    # Join new agent to callee
    # If call already exists then just dump callee.
    # Will Matrioska help here??
  end

  def call_play_recording(call, path)
    call.play! path
  rescue Adhearsion::Call::Hangup
  end

  class Plugin < Adhearsion::Plugin
    config :call_manager do
      agent_trunk         'SIP/dialler/', :desc => 'Trunk to contact agents'
      outbound_trunk      'SIP/billing/', :desc => 'Trunk to dial the PSTN'

      uri       ''         , :desc => 'URI to the Redis instance. Use this or specify each piece of connection information separately below.'
      username  ''         , :desc => 'valid database username'
      password  nil        , :desc => 'valid database password'
      host      'localhost', :desc => 'host where the database is running'
      port      6379       , :desc => 'port where the database is listening'
      db        0          , :desc => 'The redis DB number to listen to for notifications'
      socket    ''         , :desc => 'path to Unix socket where Redis is listening (Optional; to use, set host and port to nil)'
    end

    run :call_manager do
      CallManager.supervise_as :call_manager_loop
    end
  end

end
