require 'state_machine'

#FIXME: Using Enigma::Notifications.api as a generic redis interface instead of RedisPool is incorrect. Seperate the functions or refector to be more generic

class Campaign
  state_machine :status, initial: :initialized do

    after_transition do |campaign, transition|
      event, from, to = transition.event, transition.from_name, transition.to_name
      # This log message is different because the reported class name is StateMachine::Machine
      logger.info "Campaign #{campaign.ref} transitioned from #{from} to #{to} due to #{event} event."
      
      unless transition.from_name == transition.to_name
        Enigma::Notifications.api.notify :campaign, campaign.ref, :status, {status: to}
        Enigma::Notifications.client.notify :campaign, campaign.ref, :status, {status: to}, :pubsub
      end

      Enigma::Notifications.client.hset "enigma:campaigns", campaign.ref, to
    end

    before_transition any => :started do |campaign, transition|
      unless transition.from_name == transition.to_name
        # Prevent re-initializing an active worker
        Enigma::Notifications.api.sadd 'active:campaigns', campaign.ref
        campaign.initialize_workers
      end
    end

    before_transition any => :stopping do |campaign, transition|
      campaign.start_cleanup!
    end

    after_transition any => :stopping do |campaign, transition|
      campaign.try(:halt_if_able)
    end

    after_transition :stopping => :stopped do |campaign, transition|
      campaign.finish_cleanup!
    end

    event :start do
      transition any - [:stopping] => :started
      transition :stopping => :stopping
    end

    event :stop do
      transition any - [:stopped] => :stopping
      transition :stopped => :stopped
    end

    event :halt do
      transition :stopping => :stopped
    end

  end

  VALID_TYPES = %w(
    progressive
  ).freeze

  DEFAULT_SETTINGS = {
    outbound_call_id: "0123456789",
    wrapup_time: 0,
    call_timeout: 0,
    hold_timeout: 0,
    dial_from_self: false,
    dial_aggression: 1,
    notif_type: :redis,
    campaign_type: :progressive,
    moh: :silence,
    amd: true,
    agent_moh: :silence
  }.freeze

  # Campaign level settings
  attr_reader :ref
  attr_reader :stats
  attr_reader :settings
  attr_reader :call_queue
  attr_reader :call_loop
  attr_reader :call_list
  attr_reader :shutdown_mutex

  # Campaign initialization method
  # Sets up a new campaign along with it's customized settings
  # also initialises the campaigns worker threads
  def initialize(ref)
    @ref = ref
    @settings = DEFAULT_SETTINGS.dup
    @stats = Enigma::CampaignStats.new self
    @shutdown_mutex = Mutex.new

    logger.info "[#{@ref}] has been initialized"
    super()
  end

  def to_s
    "#<Campaign:#{@ref} @settings=#{@settings.inspect}, @status=\"#{@status}\", @stats=#{@stats.inspect}>"
  end
  alias :inspect :to_s

  # Spawn tasks for checking call queue, notification queue and status queues
  def initialize_workers
    # In case the queue is still alive
    begin 
      @call_queue = ElectricSlide.get_queue(@ref)
    rescue RuntimeError
    end

    # If we don't have a queue then make one
    unless @call_queue
      ElectricSlide.create @ref, ElectricSlide::CallQueue, connection_type: :bridge, agent_return_method: :manual
      # Get the queue instead of the supervision group
      @call_queue = ElectricSlide.get_queue(@ref)
    end

    unless @stats
      @stats = Enigma::CampaignStats.new self
    end

    @call_loop  = Enigma::CallLoop.new self
    @call_list = @call_loop.call_list

    logger.info "[#{@ref}] workers are initialized"
  end

  def start_cleanup!
    logger.info "[#{@ref}] Starting cleanup"
    # 1. Stop the Call Loop so no more calls go out
    stop_call_loop

    # 2. Check to see if any agents are still working
    disconnect_waiting_callees if agent_count == 0

    # 3. Update Queued Callees Stat
    @stats.account_callees nil, calls_waiting, nil, nil
  end

  def stop_call_loop
    if @call_loop
      logger.info "[#{@ref}] Shutting down the call loop"
      @call_loop.async.terminate
    end
  rescue Celluloid::DeadActorError
    logger.warn "[#{@ref}] Call Loop actor was already dead."
  end

  def disconnect_waiting_callees
    if call_waiting?
      logger.warn "[#{@ref}] Campaign shutdown requested, no agents left in the queue. Disconnecting waiting callers!"
      while call = @call_queue.get_next_caller
        begin
          logger.warn "[#{@ref}] Hanging up on call ref #{call[:callee].try(:call_ref)} (#{call.id})"
          call.hangup
        rescue *ElectricSlide::CallQueue::ENDED_CALL_EXCEPTIONS
        end
      end
    end
  end

  def disconnect_available_agents
    if !call_waiting?
      logger.warn "[#{@ref}] Campaign shutdown requested, hanging up idle agents!"
      @call_queue.get_agents.each do |agent|
        begin
            logger.warn "[#{@ref}] Hanging up agent #{agent.extension}" unless agent.on_call?
            agent.call.try(:hangup) unless agent.on_call?
        rescue *ElectricSlide::CallQueue::ENDED_CALL_EXCEPTIONS
        end
      end
    end
  end

  def halt_if_able
    logger.info "[#{@ref}] Campaign halt if able"
    if stopping? && @shutdown_mutex.try_lock

      if !call_waiting? && (agent_count == 0)
        begin
          # Celluloid::Actor[:active_campaign_list].async.halt_campaign @ref
          data = {type: 'campaign', payload: {campaign_ref: @ref, status: 'halt', internal: true}}
          Enigma::Notifications.api.rpush 'enigma:api', data.to_json

          logger.info "[#{@ref}] Campaign is halted"
        rescue StateMachine::InvalidParallelTransition
          logger.warn "[#{@ref}] Failed to transition to halted state because we are already in transition to #{self.status}"
        end
      end

      if call_waiting? && (agent_count == 0)
        logger.debug "[#{@ref}] Unable to stop due to #{calls_waiting} waiting calls - hanging up"
        disconnect_waiting_callees
      end

      if (agent_count > 0) && !call_waiting?
        logger.debug "[#{@ref}] Unable to stop due to #{agent_count} online agents - hanging up"
        # @call_queue.get_agents.each {|a| a.complete} if @call_queue
        disconnect_available_agents
      end

      @shutdown_mutex.unlock
    end

  rescue Celluloid::DeadActorError
      logger.error "[#{@ref}] is a dead actor??"
  end

  def finish_cleanup!
    logger.info "[#{@ref}] finishing cleanup."
    @call_queue = nil
    @stats = nil
    
    Enigma::Notifications.api.srem "active:campaigns", @ref
    Enigma::Notifications.client.hdel "enigma:dialler:campaigns", @ref

    ElectricSlide.shutdown_queue @ref
    Celluloid::Actor[:active_campaign_list].remove_campaign self

    logger.info "[#{@ref}] Cleanup complete."
  end

  def active?
    [:started, :stopping].include? self.status.to_sym
  end

  def alive?
    [:started].include? self.status.to_sym
  end

  def enqueue_call(call)
    if call && call.active?
      @call_queue.enqueue call
    else
      logger.warn "Can't queue call #{call[:callee].call_ref} as it is no longer active."
    end

    remove_ringing_call(call[:callee].call_ref)

    rescue Celluloid::DeadActorError, Adhearsion::Call::Hangup, Adhearsion::Call::ExpiredError
  end

  def remove_ringing_call(call_id)
    @call_list.try(:remove_ringing_call, call_id)
  end

  def add_ringing_call(call_id, call)
    @call_list.try(:add_ringing_call, call_id, call)
  end

  def moh
    @settings[:moh]
  end

  # If agent_moh isn't specified then play the callee moh
  def agent_moh
    @settings[:agent_moh]
  end

  def call_waiting?
    @call_queue.call_waiting? if @call_queue
  end

  def calls_waiting
    @call_queue.calls_waiting rescue 0
  end

  # Returns the total number of working agents in the queue, including those
  # who are in :on_call or :after_call, but excluding :unavailable
  def agent_count
    if @call_queue
      @call_queue.get_agents.select { |agent| agent.presence != :unavailable }.length
    else
      0
    end
  end

  # Returns the number of :available agents in the queue
  def available_agents
    cnt = @call_queue.available_agent_summary[:total] if @call_queue
    cnt.to_i
  end

  def todial_queue_count
    Enigma::Notifications.api.llen("campaign:#{@ref}:calls:todial").to_i
  end

  def get_calls_to_dial(n)
    to_dial = []
    Enigma::Notifications.api.pool.with do |conn|
      to_dial = conn.lrange("campaign:#{@ref}:calls:todial", 0, n-1)
      conn.ltrim("campaign:#{@ref}:calls:todial", n, -1)
    end
    logger.info "[#{@ref}] Found #{to_dial.count} of #{n} requested calls to dial"
    logger.debug "[#{@ref}] Calls to dial: #{to_dial.inspect}"
    to_dial
  end

  # Update the campaign's settings
  # @param [Hash] settings New campaign settings
  def update(new_settings)
    #Don't try change settings when the campaign is ending
    return false unless started?

    @settings = @settings.merge new_settings.symbolize_keys

    raise ArgumentError, "Invalid campaign type #{settings[:campaign_type]}; must be one of #{VALID_TYPES.join ','}" unless VALID_TYPES.include? @settings[:campaign_type].to_s

    @settings[:campaign_type] = @settings[:campaign_type].to_sym
    @settings[:notif_type] = @settings[:notif_type].to_sym

    # Force minimum wrapup of 2 seconds
    # These default overrides until issues are resolved
    @settings[:wrapup_time] = 2 unless @settings[:wrapup_time] > 2
    @settings[:dial_from_self] = false

    logger.debug "[#{@ref}] settings changed to #{@settings.inspect}"
  end

  def to_s
    "Campaign: #{ref} state: #{status} agents: #{agent_count}"
  end
end
