# mostly ripped from thrift_client

module ElasticSearch
  class NoServersAvailable < StandardError; end

  module RetryingClient

    RETRYING_DEFAULTS = {
      :randomize_server_list => true,
      :retries => nil,
      :server_retry_period => 1,
      :server_max_requests => nil,
      :retry_overrides => {}
    }.freeze

    # use cluster status to get server list
    def initialize(servers, options={})
      super
      @options = RETRYING_DEFAULTS.merge(@options)
      @retries = options[:retries] || @server_list.size
      @request_count = 0
      @max_requests = @options[:server_max_requests]
      @retry_period = @options[:server_retry_period]
      rebuild_live_server_list!
    end

    def connect!
      @current_server = next_server
      super
    rescue ElasticSearch::RetryableError
      retry
    end

    def disconnect!
      # Keep live servers in the list if we have a retry period. Otherwise,
      # always eject, because we will always re-add them.
      if @retry_period && @current_server
        @live_server_list.unshift(@current_server)
      end

      super
      @request_count = 0
    end

    #TODO this can spin indefinitely if timeout > retry_period
    def next_server
      if @retry_period
        rebuild_live_server_list! if Time.now > @last_rebuild + @retry_period
        raise NoServersAvailable, "No live servers in #{@server_list.inspect} since #{@last_rebuild.inspect}." if @live_server_list.empty?
      elsif @live_server_list.empty?
        rebuild_live_server_list!
      end
      @live_server_list.pop
    end

    def rebuild_live_server_list!
      @last_rebuild = Time.now
      if @options[:randomize_server_list]
        @live_server_list = @server_list.sort_by { rand }
      else
        @live_server_list = @server_list.dup
      end
    end

    def execute(method_name, *args)
      disconnect_on_max! if @max_requests and @request_count >= @max_requests
      retries = 0
      begin
        @request_count += 1
        super
      rescue ElasticSearch::RetryableError
        disconnect!
        retries = retries + 1
        retry unless retries > @retries
      end
    end

    def disconnect_on_max!
      @live_server_list.push(@current_server)
      disconnect!
    end
  end
end
