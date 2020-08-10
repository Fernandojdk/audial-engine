class OutboundCalleeController < Adhearsion::CallController
  def run
    @callee, campaign = metadata[:callee], metadata[:campaign]
    @callee.answered_time = Time.now

    if campaign.settings[:amd]
      case human_or_machine
      when :human
        logger.info "AMD detected HUMAN. Reason: #{human_or_machine_reason}"
      when :notsure
        logger.info "AMD inconclusive; treating as HUMAN. Reason: #{human_or_machine_reason}"
      when :machine
        logger.info "AMD detected MACHINE; hanging up on callee. Reason: #{human_or_machine_reason}"
        @callee.set_end_reason( :voicemail )
        hangup
      end
    end

    pass CalleeQueueController, callee: @callee
  end

  def human_or_machine
    # Hack around media bug: play 50ms of silence to establish the media stream from the far end
    # Without this, AMD often returns with MACHINE: INITIALSILENCE, indicating that it has not
    # heard anything at all.
    play "#{Adhearsion.root}/app/assets/audio/50ms_silence"
    execute 'AMD'
    get_variable("AMDSTATUS").downcase.to_sym
  end

  def human_or_machine_reason
    get_variable('AMDCAUSE')
  end
end
