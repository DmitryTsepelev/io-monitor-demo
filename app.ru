require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'

  gem 'rails', '~> 7.0.4'
  gem 'pg'
  gem 'webrick'
end

require 'rails/all'

username = 'postgres'
database = 'bloat_test_db'

ActiveRecord::Base.establish_connection(adapter: "postgresql", username: username, database: database)
Rails.logger = Logger.new(STDOUT)

ActiveRecord::Schema.define do
  create_table :transactions, force: true do |t|
    t.integer :amount, null: false
  end
end

class Transaction < ActiveRecord::Base; end

Transaction.insert_all(10000.times.map { |id| { amount: (rand(10) + 1) * 100 } })

class App < Rails::Application
  config.root = __dir__
  config.consider_all_requests_local = true
  config.secret_key_base = 'i_am_a_secret'
  config.active_storage.service_configurations = { 'local' => { 'service' => 'Disk', 'root' => './storage' } }

  routes.append do
    get '/slow', to: 'app#slow'
    get '/fast', to: 'app#fast'
  end
end

class AppController < ActionController::Base
  def slow
    render json: {sum: Transaction.all.sum(&:amount)}
  end

  def fast
    render json: {sum: Transaction.sum(:amount)}
  end
end

# =========

class Aggregator
  class << self
    def instance
      @instance ||= Aggregator.new
    end
  end

  attr_reader :io_bytesize

  def initialize
    clear!
  end

  def collect
    yield
    clear!
  end

  def increment(bytesize)
    @io_bytesize += bytesize
  end

  private

  def clear!
    @io_bytesize = 0
  end
end

class Railtie < Rails::Railtie
  config.after_initialize do
    ActionController::Base.prepend(Module.new do
      def process_action(*)
        Aggregator.instance.collect { super }
      end
    end)

    ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(Module.new do
      def build_result(*args, **kwargs, &block)
        io_bytesize = kwargs[:rows].sum(0) do |row|
          row.sum(0) do |val|
            ((String === val) ? val : val.to_s).bytesize
          end
        end

        Aggregator.instance.increment(io_bytesize)

        super
      end
    end)

    ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
      io_bytesize = Aggregator.instance.io_bytesize
      body_bytesize = args.last[:response].body.bytesize

      ratio = io_bytesize / body_bytesize.to_f

      Rails.logger.info "Loaded from I/O #{io_bytesize}, response bytesize #{body_bytesize}, I/O to response ratio #{ratio}"
    end
  end
end

# =========

App.initialize!

run App
