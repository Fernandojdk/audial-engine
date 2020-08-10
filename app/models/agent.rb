require 'state_machine'
require 'electric_slide/agent'

class Agent < ElectricSlide::Agent
  # # List of all the agents in all campaigns on this dialler
  attr_reader :extension
  attr_accessor :last_call_at
  attr_reader :campaign
  attr_accessor :call
  attr_reader :login_attempts
  attr_reader :address
  attr_reader :id
  attr_reader :presence
  attr_accessor :moh
  attr_reader :stats

  attr_accessor :idle_time
  attr_accessor :after_call_time
  attr_accessor :talk_time

  # Enforce backards compatibility
  def get_agent_state
    map_agent_state( @status.to_sym )
  end

  def map_agent_state(_state)
    case _state.to_sym
    when :on_call
      :busy
    when :after_call
      :wrapup
    else
      _state.to_sym
    end
  end

  # STATES
  # :offline => :logging_in #API
  # :logging_in => :available, :offline #On answed
  # :logging_out => :offline #Used to wait for the current call to end
  # :available => :connecting, :offline #On next_call
  # :connecting => :on_call, :available
  # :on_call =>  :after_call, :available, :logging_out #on call_unjoined
  # :after_call => :offline, :available #on after_call complete

  state_machine :status, initial: :offline do
    before_transition any => :offline, :do => :hangup_agent

    after_transition :offline => :logging_in do |agent, transition|
      agent.agent_login
    end

    after_transition do |agent, transition|
      event, from, to = transition.event, transition.from_name, transition.to_name
      logger.info "Agent #{agent.extension} changed from #{from} to #{to} due to #{event} event."

      if (to.to_s == "connecting") || (from.to_s == "connecting" && to.to_s == "available")
        logger.debug "Don't send a notification for #{agent.extension} as we are/were connecting..."
      else
        if agent.campaign
          Enigma::Notifications.client.hset "enigma:campaign:#{agent.campaign.ref}:agents", agent.extension, agent.get_agent_state
          agent.campaign.stats.account_agent agent.get_agent_state, agent.map_agent_state(from)
        end

        Enigma::Notifications.api.notify :agent, agent.extension, :status, {status: agent.get_agent_state}
        Enigma::Notifications.client.notify :agent, agent.extension, :status, {status: agent.get_agent_state, campaign_ref: agent.campaign.try(:ref)}, :pubsub
      end
    end

    after_transition any => :offline do |agent, transition|
      agent.idle_time = ( agent.idle_time.class == Time ) ? Time.now.to_i - agent.idle_time.to_i : nil
      agent.talk_time = ( agent.talk_time.class == Time ) ? Time.now.to_i - agent.talk_time.to_i : nil
      agent.after_call_time = ( agent.after_call_time.class == Time ) ? Time.now.to_i - agent.after_call_time.to_i : nil
      agent.update_timer_stats
    end

    after_transition :logging_in => :available do |agent, transition|
      # If we have calls waiting then assume the agent will get one soon. This is risky but required
      unless agent.campaign.call_waiting?
        # Start MOH and delay to allow the asterisk to handle the request. Agent won't be in queue yet
        agent.call.execute_controller { agent.moh = play! agent.campaign.agent_moh, repeat_times: 0 }
        sleep 1
      end

      agent.campaign.call_queue.return_agent agent, :available
    end

    after_transition :connecting => [:on_call, :logging_out] do |agent, transition|
      agent.idle_time = ( agent.idle_time.class == Time ) ? Time.now.to_i - agent.idle_time.to_i : nil
      agent.talk_time = Time.now
    end

    after_transition :after_call => :available do |agent, transition|
      # Calculare wrapup and idle times
      agent.after_call_time = ( agent.after_call_time.class == Time ) ? Time.now.to_i - agent.after_call_time.to_i : nil
      agent.update_timer_stats

      # Return the agent and update their status to available
      agent.campaign.call_queue.return_agent agent, :available

      # Reset the idle time as it is cleared when calling update_timer_stats
      agent.idle_time = Time.now
    end

    after_transition any - [:after_call] => :available do |agent, transition|
      agent.idle_time = Time.now
    end

    after_transition :on_call => :after_call do |agent, transition|
      # Start MOH, There is a natural delay here due to human time for after_call
      agent.call.execute_controller { agent.moh = play! agent.campaign.agent_moh, repeat_times: 0 }

      agent.talk_time = ( agent.talk_time.class == Time ) ? Time.now.to_i - agent.talk_time.to_i : nil
      agent.after_call_time = Time.now

      # Let the campaign know in case this was the last call of a stopping campaign
      agent.campaign.halt_if_able
    end

    event :checkin do
      transition :logging_in => :available, :if => :can_queue_agent?
      transition :on_call => :after_call, :if => :campaign_active?
      transition any => :offline, :unless => :campaign_active?
      transition :logging_out => :offline
    end

    event :complete do
      transition [:available, :after_call] => :offline#, :unless => :campaign_active?
    end

    event :checkout do
      transition :available => :connecting
    end

    event :connected do
      transition :connecting => :on_call
    end

    event :connection_failed do
      transition :connecting => :available, :if => :can_queue_agent?
      transition any => :offline, :unless => :can_queue_agent?
    end

    event :logout do
      transition all - [:connecting, :on_call] => :offline
      # There is an issue here, stats will corrupt if we go from :connection to logging_out
      transition [:connecting, :on_call] => :logging_out, :if => :can_queue_agent?
      transition [:connecting, :on_call] => :offline, :unless => :can_queue_agent?
    end

    event :login do
      transition :offline => :logging_in, :if => :campaign_alive?
      transition :after_call => :available, :if => :can_queue_agent?
    end

    event :wrappedup do
      transition :after_call => :available, :if => :can_queue_agent?
      transition any => :offline, :unless => :can_queue_agent?
    end

  end

  on_presence_change do |queue, agent_call, new_status, old_status|
    #Ignore meaningless callbacks
    unless new_status == old_status 
      agent = self
      logger.debug "Agent Presence Changed in ES: #{agent.extension} => #{new_status} from #{old_status}"

      # Ensures we set the agent to :on_call as soon as the queue checks the agent out
      if new_status == :on_call
        agent.checkout
      end

      if new_status == :unavailable
        # Only run the cleanup if the agent was active and is now offline
        agent.finish_cleanup!
      end
    end
  end

  on_connection_failed do |queue, agent_call, queued_call|
    # Place the agent back into :available state as the call coming to them failed to join.
    self.connection_failed
  end

  # Electric Slide call connected callback
  on_connect do |queue, agent_call, queued_call|
    agent = self

    begin
      agent.moh.stop! if agent.moh.try(:executing?)
    rescue
      # FIXME: Probably only want to rescue the exception raised by #stop!
    end

    begin
      queued_call[:moh].stop! if queued_call[:moh].try(:executing?)
    rescue
      # FIXME: Probably only want to rescue the exception raised by #stop!
    end

    agent.connected

    agent.last_call_at = Time.now
    agent.notify_agent(queued_call)
  end

  on_disconnect do |queue, agent_call, queued_call|
    agent = self
    if agent_call.try(:active?)
      # Puts the agent into after_call state
      agent.checkin
    end
  end

  def initialize(extension, campaign)
    @extension = extension
    @campaign = campaign
    @login_attempts = 0
    # Initialize counters to 0
    @talk_time = @idle_time = @after_call_time = 0

    @address = CallManager::Plugin.config.agent_trunk + extension
    @id = @extension

    # Ensure the agent reflects in the counters correctly
    @campaign.stats.account_agent :offline
    @stats = Enigma::AgentStats.new self

    super({id: @id, address: @address, presence: :unavailable})
  end

  def campaign_active?
    @campaign.try(:active?)
  end

  def campaign_alive?
    @campaign.try(:alive?)
  end

  def can_queue_agent?
    campaign_active? && @call.active? && @call.alive?
  end

  # Ensure the agent call is hungup, in case of API requested logout
  def hangup_agent
    @call.hangup if @call && @call.try(:active?)
  rescue Celluloid::DeadActorError, Adhearsion::Call::ExpiredError
    # In case of premature call ending.
  end

  def update_timer_stats
      # Prevent timestamps being sent, when only half a calculation has been done
      @talk_time = nil if @talk_time.class == Time
      @idle_time = nil if @idle_time.class == Time
      @after_call_time = nil if @after_call_time.class == Time

      @campaign.stats.account_agent_timers @after_call_time, @idle_time if @campaign.stats
      unless @stats
        @stats = Enigma::AgentStats.new self
      end
      @stats.account_call @talk_time, @idle_time, @after_call_time

      @talk_time = nil
      @idle_time = nil
      @after_call_time = nil
  end

  def finish_cleanup!
    @campaign.call_queue.remove_agent self if @campaign.call_queue

    logger.info "#{@extension} finished agent cleanup"

    @stats = nil
    @campaign.halt_if_able if @campaign
    rescue Celluloid::DeadActorError, Adhearsion::Call::ExpiredError
  end

  def start_cleanup!
    logger.info "#{extension} starting agent cleanup"

    Enigma::Notifications.client.hdel "enigma:campaign:#{@campaign.ref}:agents", @extension if @campaign

    if @call && !@call[:electric_slide_callback_set]
      finish_cleanup!
    else
      logger.info "#{extension} NOT finishing cleanup"
    end
  end

  def agent_login
    @call = Adhearsion::OutboundCall.new
    # This is needed as Electric Slide only passes around the agent call and not the agent
    @call[:agent] = self

    # Set the dialplan to execute for this agent
    metadata = {
      campaign: @campaign,
      agent: self,
    }
    @call.execute_controller_or_router_on_answer OutboundAgentController, metadata

    @call.on_end { |event| agent_ended(event) }

    @call.dial @address, from: @campaign.settings[:outbound_call_id]

    # Increase the number of login attempts
    @login_attempts += 1

    @campaign.call_queue.add_agent self
  end

  def notify_agent(current_call)
    if current_call.active?
      notif = {
        call_ref: current_call[:callee].call_ref,
        agent: @extension,
        contact_ref: current_call[:callee].contact_ref,
        number: current_call[:callee].number,
        campaign_ref: @campaign.try(:ref)
      }

      campaign = @campaign # Preserve scope for CallController
      agent_ext = @extension
      @call.execute_controller do
        case campaign.settings[:notif_type].to_sym
        when :sip
          send_message notif.to_json
        when :redis
          Enigma::Notifications.client.notify :agent, agent_ext, :call, notif, :pubsub
        end

        play! 'beep'
      end
    end
  end

  # Update the agents's state or campaign
  # @param [Symbol] status New agent status we want to try set
  def update_status(_status)
      case _status.to_sym
      when :wrappedup
        self.wrappedup
      when :available
        self.login
      when :offline
        self.logout
      end
  end

  def agent_ended(event)
    # If the agent is already offline don't try put them there again
    if !offline?
      self.logout
    end

    logger.debug "Agent: #{extension} has logged out with reason #{call.end_reason}"

    start_cleanup! # Cleanup the agent call and other state variables
  end

  def to_s
    "#<Agent: extension: #{extension}, campaign_ref: #{campaign.ref}, state: #{status}, call: #{@call.try(:id)}>"
  end
  alias :inspect :to_s
end

