module Enigma
  class Plugin < Adhearsion::Plugin
    config :enigma do
      http_api_base 'http://localhost:5000', desc: "Base URI to the Enigma HTTP API"
    end
  end
end
