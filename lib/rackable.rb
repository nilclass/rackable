module Rackable
#  extend(Rackable::Serialize)
  attr_reader :rack

  class MethodNotAllowed < NoMethodError
  end

  def call(env)
    allowed_methods = [:get, :put, :post, :delete]

    @rack = Struct.new(:env, :request, :response, :header, :query, :data).new
    rack.env = env

    rack.request  = Rack::Request.new(env)
    rack.response = Rack::Response.new
    rack.header   = rack.response.header

    rack.query = rack.request.GET.inject({})  {|h, (k,v)| h[k.to_sym] = v; h }
    rack.data  = rack.request.POST.inject({}) {|h, (k,v)| h[k.to_sym] = v; h }

    method = rack.env['REQUEST_METHOD'].downcase.to_sym

    path = rack.env['PATH_INFO'][1..-1]
    args = path && path.any? ? path.split('/').collect { |arg|
      Rack::Utils.unescape(arg)
    } : []

    method, was_head = :get, true if method == :head

    rack.response.status, body = catch(:halt) do
      begin
        raise MethodNotAllowed unless allowed_methods.include? method
        body = send(method, *args)
        [rack.response.status, body]

      rescue MethodNotAllowed
        rack.header['Allow'] = allowed_methods.delete_if { |meth|
          !respond_to?(meth)
        }.tap {|a|
          a.unshift 'HEAD' if respond_to? :get
        }.map { |meth|
          meth.to_s.upcase
        }.join(', ')

        http_error 405

      rescue ArgumentError
        http_error 400

      end
    end

    rack.response.write(body) unless was_head
    rack.response.finish
  end

  private

  def http_error(code, message=nil)
    throw :halt, [code, message || Rack::Utils::HTTP_STATUS_CODES[code]]
  end

end


if $0 =~ /bacon$/ && ARGV.include?(File.basename(__FILE__))
  require 'rubygems'
  require 'rack/test'

  Bacon::Context.send :include, Rack::Test::Methods

  class RestString
    include Rackable

    def initialize
      @string = "Hello, world!"
    end

    def get()
      @string
    end

    def put()
      if rack.data[:body]
        @string << rack.data[:body]
      else
        http_error 400
      end
    end

    def delete()
      if rack.query[:p]
        if @string =~ (rx = Regexp.new(rack.query[:p]))
          @string.gsub!(rx, '')
        else
          http_error 404, "Pattern #{rx.inspect} not found"
        end
      else
        @string = ""
      end
    end
  end

  class Redirecter
    extend Rackable

    def self.get
      rack.response.redirect('http://google.com')
      "hello"
    end
  end

  describe Rackable do
    before do
      def app
        RestString.new
      end
    end

    it 'provides a call() method' do
      app.should.respond_to :call
    end

    it 'calls the appropriate method on the racked object' do
      get '/'
      last_response.should.be.ok
      last_response.body.should == app.get
    end

    it 'enables HEAD requests if get is defined' do
      head '/'
      last_response.should.be.ok

      class RestString; undef_method :get; end

      head '/'
      last_response.should.not.be.ok

      class RestString; def get() @string; end end
    end

    it 'catches errors thrown inside the method' do
      put '/'
      last_response.status.should == 400
      last_response.body.should   == 'Bad Request'

      delete '/?p=nil'
      last_response.status.should == 404
    end

    it 'throws a 405 when the method is not defined' do
      post '/'
      last_response.status.should == 405
      last_response.headers['Allow'].should.not.include?('POST')
      last_response.headers['Allow'].should.    include?('GET')
    end

    it 'throws a 400 on argument errors' do
      get '/fail'
      last_response.status.should == 400
    end

    it 'prevents calling methods other than the allowed ones' do
      request '/%22foo%22', "REQUEST_METHOD" => "INSTANCE_EVAL"
      last_response.status.should == 405
    end

    describe 'Called method' do
      before do
        def app() Redirecter end
      end

      it 'can modify the response' do
        get '/'

        last_response.headers['Location'].should == 'http://google.com'
        last_response.status.should == 302
      end
    end
  end

end
