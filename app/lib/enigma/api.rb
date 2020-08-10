require 'json'
require 'singleton'

module Enigma
  class API
    include Singleton

    def initialize
      @conn = Faraday.new url: Adhearsion.config.enigma.http_api_base do |conn|
        conn.request :json
        conn.response :json, content_type: /\bjson/
        conn.adapter Faraday.default_adapter
      end
    end

    def record_inbound_call(params)
      @conn.post '/calls' do |req|
        req.body = params
      end.body
    end

    def self.method_missing(m, *args, &block)
      self.instance.send m, *args, &block
    end
  end
end
