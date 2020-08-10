class CalleeQueueController < Adhearsion::CallController
  def run
    @callee = metadata[:callee]
    @campaign = @callee.campaign

    start_moh
    record_call
    call.auto_hangup = false

    # TODO count dropped calls
    # TODO Make calls save CDR to asterisk cdr DB

    @campaign.enqueue_call call
  end


  def start_moh
    call[:moh] = play! @campaign.moh, repeat_times: 0
  end

  def record_call
    # Locking format down to WAV, as it is the only self-describing format we can easily record to.
    # http://sox.sourceforge.net/AudioFormats-6.html
    format = 'WAV'
    record async: true, format: format do |event|
      logger.warn "recording location is empty for #{event.recording.uri}" if @callee.recording_location.nil? || @callee.recording_location.empty?
      @callee.set_recording_extension(File.extname(event.recording.uri))
      Celluloid::Actor[:recording_manager].store_recording(event.recording.uri, @callee.recording_location)
    end
  end

end
