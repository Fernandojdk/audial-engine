source 'https://rubygems.org'

ruby '2.2.3', engine: 'jruby', engine_version: '9.0.5.0'
#ruby=jruby-1.7.19

gem 'adhearsion', "~> 2.6"
gem 'punchblock', github: 'adhearsion/punchblock', branch: 'develop'
gem 'celluloid', '~> 0.15.0'

# This is here by default due to deprecation of #ask and #menu.
# See http://adhearsion.com/docs/common_problems#toc_3 for details
# gem 'adhearsion-asr'

gem "statsd-ruby"
gem 'redis'
gem 'timers'
gem 'thread_safe'
gem 'state_machine'
gem 'rb-inotify'
gem 'loguse'

gem 'electric_slide', github: 'platforma/electric_slide', branch: 'bugfix/nil-calls-in-queue-fixed'

# CONNECTION POOL FOR SUSTAINABLE REDIS USAGE
gem 'connection_pool', '2.1.1'
# Easy to use LUA scripting for REDIS
gem 'redis-scripting'
gem 'jruby-openssl', '0.9.6'

gem 'deep_enumerable'

gem 'faraday'
gem 'faraday_middleware'

# Here are some example plugins you might like to use. Simply
# uncomment them and run `bundle install`.
#

# gem 'adhearsion-rails'
# gem 'adhearsion-activerecord'
# gem 'adhearsion-ldap'
# gem 'adhearsion-xmpp'
# gem 'adhearsion-drb'

# Needed for AMD
gem 'adhearsion-asterisk'

group :development, :test do
  gem 'rspec'
  gem 'pry'
  gem 'thor'
end


