#
# Copyright (c) 2007-2009 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#
module Rightscale
  module Rackspace

    class BenchmarkingBlock #:nodoc:
      attr_accessor :parser, :service
      def initialize
        # Benchmark::Tms instance for service access benchmarking.
        @service = Benchmark::Tms.new()
        # Benchmark::Tms instance for parsing benchmarking.
        @parser = Benchmark::Tms.new()
      end
    end

    class Interface
      DEFAULT_AUTH_ENDPOINT = "https://auth.api.rackspacecloud.com"
      DEFAULT_LIMIT = 1000

      @@rackspace_problems = []
      def self.rackspace_problems
        @@rackspace_problems
      end

      @@bench = Rightscale::Rackspace::BenchmarkingBlock.new
      def self.bench
        @@bench
      end

      @@params = {}
      def params
        @@params
      end
      
      @@caching = false

      attr_reader   :username
      attr_reader   :auth_key
      attr_reader   :logged_in
      attr_reader   :auth_headers
      attr_reader   :auth_token
      attr_reader   :auth_endpoint
      attr_reader   :service_endpoint
      attr_accessor :last_request
      attr_accessor :last_response
      attr_accessor :last_error
      attr_reader   :logger
      attr_reader   :cache

      def params
        @@params.merge(@params)
      end

      def endpoint_to_host_data(endpoint)
        service = URI.parse(endpoint).path
        service.chop! if service[/\/$/]  # remove a trailing '/'
        { :server   => URI.parse(endpoint).host,
          :service  => service,
          :protocol => URI.parse(endpoint).scheme,
          :port     => URI.parse(endpoint).port }
      end

      # Params:
      #  :logger,
      #  :caching - bool
      #  :verbose_errors - bool
      def initialize(username, auth_key, params={})
        @params = params
        # Auth data
        @username  = username
        @auth_key  = auth_key
        @logged_in = false
        # Auth host
        @auth_headers  = {} # a set of headers is returned on authentification coplete
        @auth_endpoint = ENV['RACKSPACE_AUTH_ENDPOINT'] || params[:auth_endpoint] || DEFAULT_AUTH_ENDPOINT
        @auth_endpoint_data = endpoint_to_host_data(@auth_endpoint)
        # Logger
        @logger = @params[:logger] || (defined?(RAILS_DEFAULT_LOGGER) && RAILS_DEFAULT_LOGGER) || Logger.new(STDOUT)
        # Request and response
        @last_request = nil
        @last_response = nil
        # cache
        @cache = {}
      end

      #
      # options:
      #   :body           => String
      #   :headers        => Hash|Array
      #   :endpoint_data  => Hash
      #   :vars           => hash
      #
      def generate_request(verb, path='', options={}) #:nodoc:
        # Form a valid http verb: 'Get', 'Post', 'Put', 'Delete'
        verb = verb.to_s.capitalize
        raise "Unsupported HTTP verb #{verb.inspect}!" unless verb[/^(Get|Post|Put|Delete)$/]
        # Select an endpoint
        endpoint_data = (options[:endpoint_data] || @service_endpoint_data).dup
        # Fix a path
        path = "/#{path}" if !path.empty? && !path[/^\//]
        # Request variables
        request_params = options[:vars].to_a.map do |key, value|
          key = key.to_s.downcase
          # Make sure we do not pass a Time object instead of integer for 'changes-since'
          value = value.to_i if key == 'changes-since'
          "#{URI.escape(key)}=#{URI.escape(value.to_s)}"
        end.join('&')
        # Build a request final path
        request_path  = "#{endpoint_data[:service]}#{path}"
        request_path  = '/' if request_path.blank?
        request_path += "?#{request_params}" unless request_params.blank?
        # Create a request
        request = eval("Net::HTTP::#{verb}").new(request_path)
        request.body = options[:body] if options[:body]
        # Set headers
        options[:headers].to_a.each { |key, value| request[key] = value }
        # prepare output hash
        endpoint_data.merge(:request => request)
      end

      # Just requests a remote end
      def internal_request_info(request_hash) #:nodoc:
        result = nil
        @connection  ||= Rightscale::HttpConnection.new(:exception => Error, :logger => @logger)
        @@bench.service.add!{ result = @connection.request(request_hash) }
        result
      end

      # Request a remote end and process any errors is found
      def request_info(request_hash) #:nodoc:
        @last_request  = request_hash[:request]
        @last_response = internal_request_info(request_hash)
        result = nil
        # check response for success...
        if @last_response.is_a?(Net::HTTPSuccess)
          # SUCCESS
          @error_handler = nil
          case @last_response.code 
          when '203'
            # 203 + an empty response body means we asked whether the valud did not change and it hit
            if @last_response.body.blank?
              path = cached_path(@last_request.path)
              last_modified_at = @cache[path][:last_modified_at]
              raise NoChange.new("Cached: '#{path}' has not changed since #{last_modified_at}.")
            end
          end
          # Parse a response body. If the body is empty the return +true+
          @@bench.parser.add! do
            result = if @last_response.body.blank? then true
                     else
                       case @last_response['content-type'].first
                       when 'application/json' then JSON::parse(@last_response.body)
                       else @last_response.body
                       end
                     end
          end
        else
          # ERROR
          case @last_response.code
          when '304' 
            @error_handler = nil
            raise NoChange.new("NotModified: '#{simple_path(@last_request.path)}' has not changed since the requested time.")
          end
          @error_handler ||= HttpErrorHandler.new(self, :errors_list => self.class.rackspace_problems)
          result           = @error_handler.check(request_hash)
          @error_handler   = nil
          raise Error.new(@last_error) if result.nil?
        end
        result
      rescue
        @error_handler = nil
        raise
      end

      #  simple_path('/v1.0/123456/images/detail?var1=var2') #=> '/images/detail?var1=var2'
      def simple_path(path) # :nodoc:
        (path[/^#{@service_endpoint_data[:service]}(.*)/] && $1) || path
      end

      #  simple_path('/v1.0/123456/images/detail?var1=var2') #=> '/images/detail'
      def cached_path(path) # :nodoc:
        simple_path(path)[/([^?]*)/] && $1
      end

      #  detailed_path('/images', true) #=> '/images/detail'
      def detailed_path(path, options) # :nodoc:
        "#{path}#{options[:detail] ? '/detail' : ''}"
      end

      # Authenticate a user.
      # Params:  +soft+ is used for auto-authentication when auth_token expires. Soft auth
      # do not overrides @last_request and @last_response attributes (are needed for a proper
      # error handling) on success.
      def authenticate(soft=nil) # :nodoc:
        @logged_in    = false
        @auth_headers = {}
        request_data  = generate_request( :get, '',
                                          :endpoint_data  => @auth_endpoint_data,
                                          :headers        => { 'x-auth-user' => @username,
                                                               'x-auth-key'  => @auth_key } )
        logger.info ">>>>> Authenticating ..."
        if soft
          response = internal_request_info(request_data)
          unless response.is_a?(Net::HTTPSuccess)
            @last_request  = request_data[:request]
            @last_response = response
            @error_handler = nil
            raise Error.new(HttpErrorHandler::extract_error_description(response, params[:verbose_errors]))
          end
        else
          request_info(request_data)
          response = @last_response
        end
        logger.info ">>>>> Authenticated successfully."
        # Store all auth response headers
        @auth_headers = response.to_hash
        @auth_token   = @auth_headers['x-auth-token'].first
        # Service endpoint
        @service_endpoint      = params[:service_endpoint] || @auth_headers['x-compute-url'].first
        @service_endpoint_data = endpoint_to_host_data(@service_endpoint)
        @logged_in = true
      end

      # Incrementally lists something.
      def incrementally_list_resources(verb, path, offset=nil, limit=nil, opts={}, &block) # :nodoc:
        opts = opts.dup
        opts[:vars] ||= {}
        opts[:vars]['offset'] = offset || 0
        opts[:vars]['limit']  = limit  || DEFAULT_LIMIT
#        full_path = detailed_path(path, opts)
        # Get a resource name:
        #   '/images'         => 'images'
        #   '/servers/detail' => 'servers'
        resources = path[%r{^/([^/]*)}] && $1
        result    = { resources => []}
        loop do
          begin
            response = api(verb, path, opts)
            result[resources] += response[resources]
          rescue Rightscale::Rackspace::Error => e
            raise e unless e.message[/itemNotFound/]
            response = nil
          end
          break if response.blank? || response[resources].blank? || (block && !block.call(response))
          opts[:vars]['offset'] += opts[:vars]['limit']
        end
        result
      end

      # Call Rackspace. Caching is not used.
      def api(verb, path='', options={}) # :nodoc:
        login unless @logged_in
        options[:headers] ||= {}
        options[:headers]['x-auth-token'] = @auth_token
        request_info(generate_request(verb, path, options))
      end

      # Call Rackspace. Use cache if possible
      # opts:
      #  :incrementally - use incrementally list to get the whole list of items
      #  otherwise it will get max DEFAULT_LIMIT items (PS API call must support pagination)
      #
      def api_or_cache(verb, path, options={})
        use_caching  = params[:caching] && options[:vars].blank?
        cache_record = use_caching && cached?(path)
        # Create a proc object to avoid a code duplication
        proc = Proc.new do
          if options[:incrementally]
               incrementally_list_resources(verb, path, nil, nil, options)
          else api(verb, path, options)
          end
        end
        # The cache is not used or record is not found
        unless cache_record
          response = proc.call
          if use_caching
            last_modified_at = @last_response.to_hash['last-modified'].first
            update_cache(path, last_modified_at, response)
          end
          response
        else
          # Record found - ask Rackspace whether it changed or not since last update
          options = options.dup
          options[:headers] ||= {}
          options[:headers]['if-modified-since'] = cache_record[:last_modified_at]
          proc.call
        end
      end

      #------------------------------------------------------------
      # Caching
      #------------------------------------------------------------

      def cached?(path)
        @cache[path]
      end

      def update_cache(path, last_modified_at, data)
        @cache[path] ||= {}
        @cache[path][:last_modified_at] = last_modified_at
        @cache[path][:data] = data
      end

    end

    #------------------------------------------------------------
    # Error handling
    #------------------------------------------------------------

    class NoChange < RuntimeError #:nodoc:
    end

    class Error < RuntimeError
    end

    class HttpErrorHandler

      # Receiving these codes we have to reauthenticate at Rackspace
      REAUTHENTICATE_ON = ['401']
      # Some error are too ennoing to be logged: '404' comes very often when one calls
      # incrementally_list_something
      SKIP_LOGGING_ON   = ['404']

      @@reiteration_start_delay = 0.2
      def self.reiteration_start_delay
        @@reiteration_start_delay
      end
      def self.reiteration_start_delay=(reiteration_start_delay)
        @@reiteration_start_delay = reiteration_start_delay
      end
      @@reiteration_time = 5
      def self.reiteration_time
        @@reiteration_time
      end
      def self.reiteration_time=(reiteration_time)
        @@reiteration_time = reiteration_time
      end

      # Format a response error message.
      def self.extract_error_description(response, verbose=false) #:nodoc:
        message = nil
        Interface::bench.parser.add! do
          message = begin
                      if response.body[/^<!DOCTYPE HTML PUBLIC/] then response.message
                      else
                        JSON::parse(response.body).to_a.map do |k,v|
                          "#{k}: #{v['message']}" + (verbose ? "\n#{v['details']}" : "")
                        end.join("\n")
                      end
                    rescue
                      response.message
                    end
        end
        "#{response.code}: #{message}"
      end

      # params:
      #  :reiteration_time
      #  :errors_list
      def initialize(handle, params={}) #:nodoc:
        @handle        = handle           # Link to RightEc2 | RightSqs | RightS3 instance
        @started_at    = Time.now
        @stop_at       = @started_at  + (params[:reiteration_time] || @@reiteration_time)
        @errors_list   = params[:errors_list] || []
        @reiteration_delay = @@reiteration_start_delay
        @retries       = 0
      end

      # Process errored response
      def check(request)  #:nodoc:
        result      = nil
        error_found = false
        response    = @handle.last_response
        error_message = HttpErrorHandler::extract_error_description(response, @handle.params[:verbose_errors])
        # Log the error
        logger = @handle.logger
        unless SKIP_LOGGING_ON.include?(response.code)
          logger.warn("##### #{@handle.class.name} returned an error: #{error_message} #####")
          logger.warn("##### #{@handle.class.name} request: #{request[:server]}:#{request[:port]}#{request[:request].path} ####")
        end
        # Get the error description of it is provided
        @handle.last_error = error_message
        # now - check the error
        @errors_list.each do |error_to_find|
          if error_message[/#{error_to_find}/i]
            error_found = error_to_find
            logger.warn("##### Retry is needed, error pattern match: #{error_to_find} #####")
            break
          end
        end
        # yep, we know this error and have to do a retry when it comes
        if error_found || REAUTHENTICATE_ON.include?(@handle.last_response.code)
          # check the time has gone from the first error come
          # Close the connection to the server and recreate a new one.
          # It may have a chance that one server is a semi-down and reconnection
          # will help us to connect to the other server
          if (Time.now < @stop_at)
            @retries += 1
            @handle.logger.warn("##### Retry ##{@retries} is being performed. Sleeping for #{@reiteration_delay} sec. Whole time: #{Time.now-@started_at} sec ####")
            sleep @reiteration_delay
            @reiteration_delay *= 2
            # Always make sure that the fp is set to point to the beginning(?)
            # of the File/IO. TODO: it assumes that offset is 0, which is bad.
            if request[:request].body_stream && request[:request].body_stream.respond_to?(:pos)
              begin
                request[:request].body_stream.pos = 0
              rescue Exception => e
                logger.warn("Retry may fail due to unable to reset the file pointer -- #{self.class.name} : #{e.inspect}")
              end
            end
            # Oops it seems we have been asked about reauthentication..
            if REAUTHENTICATE_ON.include?(@handle.last_response.code)
              @handle.authenticate(:soft)
              @handle.request_info(request)
            end
            # Make another try
            result = @handle.request_info(request)
          else
            logger.warn("##### Ooops, time is over... ####")
          end
        end
        result
      end

    end
  end
end