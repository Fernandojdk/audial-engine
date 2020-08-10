class InboundCalleeController < Adhearsion::CallController

  def run
    reject unless campaign = lookup_campaign
    call_ref = create_cdr campaign.ref, stripped_number(call.from)

    callee_opts = {
      call: call,
      campaign: campaign,
      call_ref: call_ref,
      number: stripped_number(call.from)
    }
    callee = Callee.new :inbound, callee_opts

    answer
    callee.answered_time = Time.now

    pass CalleeQueueController, callee: callee
  end

  def lookup_campaign
    # Try finding the campaign by reference first; then fall back to
    # finding it by outbound phone number
    Celluloid::Actor[:active_campaign_list].get_campaign(stripped_number(call.to)) ||
    Celluloid::Actor[:active_campaign_list].get_campaign_by_number(stripped_number(call.to))
  end

  def create_cdr(campaign_ref, number)
    cdr = Enigma::API.record_inbound_call call: {campaign_ref: campaign_ref, number: number}
    # The CDR's ID is the internal call_ref
    cdr["id"]
  end

  def stripped_number(uri)
    # NOTE: This expects Asterisk-style addresses, and will need to be updated for FreeSWITCH
    # Examples, when expecting "1234":
    # SIP/foo/1234
    # SIP/1234@foo
    # unknown <SIP/1234>
    match = uri.match /<(.*)>/
    uri = match ? match[1] : uri
    uri.split('/').last.split('@').first
  end
end
