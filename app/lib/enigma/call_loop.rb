require 'thread'

module Enigma
  class CallList
    attr_reader :calls_ringing
    attr_reader :mutex

    def initialize
      @calls_ringing = {}
      @mutex = Mutex.new
    end

    def add_ringing_call(id, call)
      @mutex.synchronize do 
        @calls_ringing[id] = call
      end
    end

    def remove_ringing_call(id)
      @mutex.synchronize do 
        @calls_ringing.delete id
      end
    end

    def ringing_call_count
      @mutex.synchronize do 
        @calls_ringing.length
      end
    end

    def calls_ringing
      @mutex.synchronize do
        calls_ringing.dup
      end
    end
  end
end

module Enigma
  class CallLoop
    include Celluloid

    finalizer :finalizer

    attr_reader :campaign
    attr_reader :start_time
    attr_reader :call_list
    attr_reader :running

    attr_reader :callees_pending
    attr_reader :callees_inprogress
    attr_reader :callees_complete
    attr_reader :callees_failed
    attr_reader :last_queue_request
    attr_reader :queued_calls

    attr_accessor :recalculation_interval

    def initialize(campaign)
      @campaign = campaign
      @last_queue_request = 0
      @call_list = Enigma::CallList.new
      @running = true
      @mutex = Mutex.new
      @can_request_calls_mutex = true
      @start_time = Time.now

      every 5 do
        begin
          if @mutex.try_lock
            self.call_loop if @running
            @mutex.unlock
          end
        rescue Celluloid::DeadActorError, ThreadError
        end
      end
    end

    def to_s
      "#<Enigma::CallLoop:#{self.object_id.to_s(16)} @running=#{@running.inspect} @start_time=\"#{@start_time.inspect}\">"
    end
    alias :inspect :to_s

    def finalizer
      @running = false
      @call_list.calls_ringing.values.each do |call|
        # Must call async, see https://github.com/celluloid/celluloid/wiki/Finalizers
        # Failing to call other actors async will raise Task::TerminatedError
        call.async.hangup
      end

      logger.debug "Call loop [#{campaign.ref}] has been shutdown."
    end

    def call_loop
      available_agents = @campaign.available_agents

      logger.debug "Call loop - Available Agent(s): #{available_agents} - Campaign Status: #{@campaign.status} - Queued Calls: #{@campaign.calls_waiting}"
      # Update the number of callees in the queue
      if @queued_calls != @campaign.calls_waiting
        @campaign.stats.account_callees nil, @campaign.calls_waiting, nil, nil
        @queued_calls = @campaign.calls_waiting
      end


      if @running && @campaign.status.to_sym == :started && available_agents > 0
        n_ringing_calls = @call_list.ringing_call_count
        calls_to_place = [available_agents - n_ringing_calls, 0].max * @campaign.settings[:dial_aggression]

        logger.debug "Dial Count: #{calls_to_place} - Calls still ringing: #{n_ringing_calls}"

        if calls_to_place > 0

          if (@campaign.todial_queue_count < 2*calls_to_place)
            # This will ensure enough calls are on the queue for worst case
            request_more_calls(@campaign.agent_count * @campaign.settings[:dial_aggression])
          end

          dial_list = @campaign.get_calls_to_dial calls_to_place

          dial_list.each do |call_request|
            params = JSON.parse(call_request)

            logger.info "Dialling Callee: #{params['contact_ref']} on number #{params['number']}"

            callee = Callee.new :outbound, campaign: @campaign, call_ref: params['call_ref'], contact_ref: params['contact_ref'], number: params['number']
          end
        end
      end
    end

    def request_more_calls(n)
      #  If the mutex is locked and the timeout of 10seconds has been exceeded then unlock it so we can request more calls again
      if !@can_request_calls_mutex && ( Time.now.to_i - @last_queue_request > 10 )
        @can_request_calls_mutex = true
      end

      if @can_request_calls_mutex
        @can_request_calls_mutex = false
        Enigma::Notifications.api.notify :campaign, @campaign.ref, :queue_calls, {rate: n}
        @last_queue_request = Time.now.to_i
      end
    end

    def update_status(remaining_callees, currently_dialing, dial_preview_list, completed_callees, callees_failed)
      @callees_pending = remaining_callees
      @callees_inprogress = currently_dialing
      @callees_complete = completed_callees
      @callees_failed = callees_failed

      logger.debug "Updating call loop status: pending=#{@callees_pending} inprogress=#{@callees_inprogress} todial=#{@campaign.todial_queue_count}"

      # Shutdown the campaign as we are out of callees to dial
      if ( @callees_pending == 0 ) && ( @callees_inprogress == 0 ) && @campaign.started?
        logger.info "Stopping campaign #{@campaign.ref} as it's out of calls"
        data = {type: 'campaign', payload: {campaign_ref: @campaign.ref, status: 'stop'}}
        Enigma::Notifications.api.rpush 'enigma:api', data.to_json
        # Celluloid::Actor[:active_campaign_list].async.stop_campaign @campaign.ref
      end

      unless dial_preview_list.empty?
        Enigma::Notifications.client.notify :campaign, @campaign.ref, :dial_preview, { callees: dial_preview_list }, :pubsub
      end

      # Update the number of callees still remaining
      @campaign.stats.account_callees @callees_pending, nil, @callees_complete, @callees_failed

      # Unlock the mutex as getting this notification means new calls have been queued
      if !@can_request_calls_mutex
        @can_request_calls_mutex = true
      end
    end

  end
end
