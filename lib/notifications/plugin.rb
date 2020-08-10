require_relative 'lib/notifier'

module Enigma
  class Notifications
    include Singleton
    
    cattr_accessor :client
    cattr_accessor :api

    class << self

      def establish_connections(config)
        params = config.to_hash.select { |k,v| !v.nil? }
        n_config = {}
        n_config[:uri] = params.delete :api_uri
        n_config[:pool_size] = params.delete :api_pool_size
        n_config[:pool_timeout] = params.delete :api_timeout
        n_config[:redis_scripts] = params.delete :api_redis_scripts
        n_config[:base_key] = params.delete :api_base_key

        @@api = Enigma::Notifier.new 'API', n_config

        n_config = {}
        n_config[:uri] = params.delete :client_uri
        n_config[:pool_size] = params.delete :client_pool_size
        n_config[:pool_timeout] = params.delete :client_timeout
        n_config[:redis_scripts] = params.delete :client_redis_scripts
        n_config[:base_key] = params.delete :client_base_key

        @@client = Enigma::Notifier.new 'CLIENT', n_config     
      end
    end

    class Plugin < Adhearsion::Plugin
      config :enigma_notification_config do
          api_uri 'redis://127.0.0.1:6379/0'          , :desc => 'a valid redis connection URL, used to connect to the API redis instance. e.g. "redis://user:pwd@host:port/db"'
          api_pool_size 5                             , :desc => 'number of connections in the api notification redis connection pool'
          api_timeout   5                             , :desc => 'time to wait for a connection to become available'
          api_redis_scripts   ''                      , :desc => 'path to the lua scripts directory for use with either redis instance'
          api_base_key  'enigma:notifications'        , :desc => 'the notifications namespace, this is prepended to all notifications'

          client_uri 'redis://127.0.0.1:6379/0'          , :desc => 'a valid redis connection URL, used to connect to the client redis instance. e.g. "redis://user:pwd@host:port/db"'
          client_pool_size 5                             , :desc => 'number of connections in the client notification redis connection pool'
          client_timeout   5                             , :desc => 'time to wait for a connection to become available'
          client_redis_scripts   ''                      , :desc => 'path to the lua scripts directory for use with either redis instance'
          client_base_key  'enigma:notifications'        , :desc => 'the notifications namespace, this is prepended to all notifications'
      end

      run :redis_connection_pool do
        Enigma::Notifications.establish_connections Adhearsion.config[:enigma_notification_config]
      end
    end
  end
end
