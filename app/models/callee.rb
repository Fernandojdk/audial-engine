class Callee
  attr_reader :number
  attr_reader :call_ref
  attr_reader :end_reason
  attr_reader :end_code
  attr_reader :contact_ref
  attr_reader :agent_ext
  attr_reader :recording_location
  attr_reader :route
  attr_reader :callee_address
  attr_accessor :outbound_id

  attr_accessor :dialled_time
  attr_accessor :answered_time
  attr_accessor :joined_time
  attr_accessor :end_time
  attr_accessor :campaign
  attr_accessor :call

  def initialize(direction, opts = {})
    required_keys = [:campaign, :call_ref, :number]
    required_keys << :call if direction == :inbound
    required_keys << :contact_ref if direction == :outbound
    required_keys.each do |key|
      raise ArgumentError, "Must specify a #{key.inspect} key when instantiating the Callee" unless opts.has_key? key
    end

    @campaign = opts[:campaign]
    @call_ref = opts[:call_ref]
    @number = opts[:number]

    case direction
    when :outbound
      init_outbound opts[:contact_ref]
    when :inbound
      init_inbound opts[:call]
    else
      raise ArgumentError, "Could not find a callee initializer for #{direction}"
    end
  end

  # Initialization method for a new call
  def init_outbound(contact_ref)
    @contact_ref = contact_ref
    @route = :outbound

    build_outbound_call

    init_common

    @dialled_time = Time.now
    @campaign.add_ringing_call @call_ref, @call 
    @call.dial @callee_address, from: @outbound_id
  end

  # Initialization method for when a call already exists
  def init_inbound(call)
    @call = call
    @call.tag(@call_ref.to_s)
    @call[:callee] = self
    @dialled_time = @call.start_time
    @route = :inbound
    init_common
  end

  def init_common
    @call.on_end { |event| callee_ended(event) }
  end

  def build_outbound_call
    @outbound_id = (@campaign.settings[:dial_from_self]) ? @number : @campaign.settings[:outbound_call_id]
    @callee_address = CallManager::Plugin.config.outbound_trunk + @number

    @call = Adhearsion::OutboundCall.new
    @call[:callee] = self

    # Set the dialplan to execute for this agent
    metadata = {
      campaign: @campaign,
      callee: self,
    }
    @call.execute_controller_or_router_on_answer OutboundCalleeController, metadata

    @call.tag(@call_ref.to_s)
  end

  def callee_ended(event)
    @end_reason = @call.end_reason unless @end_reason

    # Remap Adhearsion dispositions
    case @end_reason
    when :hungup
      @end_reason = :callee_hungup
    when :hangup_command
      @end_reason = :agent_hungup
    end

    @end_code = @call.end_code
    @campaign.remove_ringing_call(@call_ref)
    @end_time = Time.now

    send_cdr

    cleanup
  end

  def set_end_reason(reason)
    @end_reason = reason.to_sym
  end

  def handled_by(agent)
    @joined_time = Time.now
    @agent_ext = agent.extension
    @recording_location = TFDialer::Recordings.get_recording_location(@joined_time, @call.id, @number, @agent_ext)
  end

  def set_recording_extension(extension)
    @recording_location = "#{recording_location}#{extension}"
  end

  def cleanup
    logger.debug "Cleaning up callee #{@call_ref} as the call ended."
    # Account the call in the call stats
    @campaign.stats.account_call @dialled_time, @answered_time, @joined_time, @end_time, @end_reason, @route if @campaign
    @campaign.halt_if_able if @campaign && @answered_time

    # In case of a status call after we delete the call
    @call = nil
  end

  def send_cdr
    logger.debug "Sending CDR for call #{@call_ref} which ended with #{@end_reason}."

    cdr = {}
    cdr[:call_ref] = @call_ref
    cdr[:uuid] = @call.id if @call
    cdr[:agent] = @agent_ext
    cdr[:recording_location] = @recording_location
    cdr[:dialed_at] = @dialled_time
    cdr[:callee_answered_at] = @answered_time
    cdr[:agent_answered_at] = @joined_time
    cdr[:ended_at] = @end_time
    cdr[:end_reason] = @end_reason
    cdr[:call_dir] = @route

    Enigma::Notifications.api.notify :cdr, nil, :call_update, cdr

    # FIXME: Make our API use the same CDR record, we can add in a few additional fields to ours. Thus send client CDR, add fields, send API CDR
    # This will just have to do for now, don't have time to properly test new API implemnetations

    if @campaign.settings[:notif_type].to_sym == :redis || @campaign.settings[:notif_type].to_sym == :sip
      cdr = {}
      cdr[:extension] = @agent_ext
      cdr[:number] = @number
      cdr[:dial_number] = @campaign.settings[:outbound_call_id]
      cdr[:recording_url] = @recording_location
      cdr[:call_ref] = @call_ref
      cdr[:contact_ref] = @contact_ref
      cdr[:dialed_at] = @dialled_time.to_i        # Make Unix timestamp
      cdr[:call_time] = (@joined_time) ? @end_time.to_i - @joined_time.to_i : 0
      cdr[:end_reason] = @end_reason
      cdr[:end_code] = @end_code
      cdr[:call_dir] = @route

      Enigma::Notifications.client.notify :campaign, @campaign.ref, :cdr, cdr
      Enigma::Notifications.api.notify nil, nil, nil, cdr, :internal
    end

  end

  def call_id
    @call.id
  end

end
