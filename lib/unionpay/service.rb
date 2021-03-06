#encoding:utf-8
require 'open-uri'
require 'digest'
require 'base64'
require 'rack'
require 'net/http'
require 'rest-client'
require 'openssl'
module UnionPay
  RESP_SUCCESS  = '00' #返回成功
  QUERY_SUCCESS = '0' #查询成功
  QUERY_FAIL    = '1'
  QUERY_WAIT    = '2'
  QUERY_INVALID = '3'
  class Service
    attr_accessor :args, :api_url

    def self.front_pay(param)
      new.instance_eval do
        param['txnTime']         ||= Time.now.strftime('%Y%m%d%H%M%S')         #交易时间, YYYYmmhhddHHMMSS
        param['currencyCode']     ||= UnionPay::CURRENCY_CNY                    #交易币种，CURRENCY_CNY=>人民币
        param['txnType']         ||= UnionPay::CONSUME
        param['txnSubType'] ||= '01'
        param['bizType']  ||='000000'
        param['channelType'] ||='07'
        param['accessType'] ||='0'
        trans_type = param['txnType']
        if [UnionPay::CONSUME, UnionPay::PRE_AUTH].include? trans_type
          @api_url = UnionPay.front_pay_url
          self.args = PayParamsEmpty.merge(PayParams).merge(param)
          @param_check = UnionPay::PayParamsCheck
        else
          # 前台交易仅支持 消费 和 预授权
          raise("Bad trans_type for front_pay. Use back_pay instead")
        end
        service
      end
    end

    def self.back_pay(param)
      new.instance_eval do
        param['txnTime']         ||= Time.now.strftime('%Y%m%d%H%M%S')         #交易时间, YYYYmmhhddHHMMSS
        param['currencyCode']     ||= UnionPay::CURRENCY_CNY                    #交易币种，CURRENCY_CNY=>人民币
        param['txnType']         ||= UnionPay::REFUND
        @api_url = UnionPay.back_pay_url
        self.args = PayParamsEmpty.merge(PayParams).merge(param)
        @param_check = PayParamsCheck
        trans_type = param['txnType']
        if [UnionPay::CONSUME, UnionPay::PRE_AUTH].include? trans_type
          if !self.args['cardNumber'] && !self.args['pan']
            raise('consume OR pre_auth transactions need cardNumber!')
          end
        else
          raise('origQid is not provided') if UnionPay.empty? self.args['origQid']
        end
        service
      end
    end

    def self.response(param)
      new.instance_eval do
        if param.is_a? String
          param = Rack::Utils.parse_nested_query param
          p param
        end
        if param['respCode'] != "00"
          return false
        end
        if !param['signature'] || !param['signMethod']
          return false
        end
        sig=param.delete("signature").gsub(' ','+')
        sign_str = param.sort.map do |k,v|
          "#{k}=#{v}&"
        end.join.chop
        p "sig:#{sig}"
        digest = OpenSSL::Digest::SHA1.new
        if !UnionPay.public_key.verify digest, Base64.decode64(sig), Digest::SHA1.hexdigest(sign_str)
          return false
        end
        param
      end
    end

    def self.query(param)
      new.instance_eval do
        @api_url = UnionPay.query_url
        param['version'] = UnionPay::PayParams['version']
        param['charset'] = UnionPay::PayParams['charset']
        param['merId'] = UnionPay::PayParams['merId']

        if UnionPay.empty?(UnionPay::PayParams['merId']) && UnionPay.empty?(UnionPay::PayParams['acqCode'])
          raise('merId and acqCode can\'t be both empty')
        end
        if !UnionPay.empty?(UnionPay::PayParams['acqCode'])
          acq_code = UnionPay::PayParams['acqCode']
          param['merReserved'] = "{acqCode=#{acq_code}}"
        else
          param['merReserved'] = ''
        end

        self.args = param
        @param_check = UnionPay::QueryParamsCheck

        service
      end
    end

    def self.sign(param)
      sign_str = param.sort.map do |k,v|
        "#{k}=#{v}&"
      end.join.chop
      digest=OpenSSL::Digest::SHA1.new
      ::Base64.encode64(UnionPay.security_key.sign digest, Digest::SHA1.hexdigest(sign_str)).gsub("\n","")
    end

    def form(options={})
      attrs = options.map { |k, v| "#{k}='#{v}'" }.join(' ')
      html = [
        "<form #{attrs} action='#{@api_url}' method='post'>"
      ]
      args.each do |k, v|
        html << "<input type='hidden' name='#{k}' value='#{v}' />"
      end
      if block_given?
        html << yield
        html << "</form>"
      end
      html.join
    end

    def post
      res = RestClient.post(@api_url, self.args)
    end

    def [](key)
      self.args[key]
    end

    private
    def service
      if self.args['commodityUrl']
        self.args['commodityUrl'] = URI::encode(self.args['commodityUrl'])
      end

      arr_reserved = []
      UnionPay::MerParamsReserved.each do |k|
        arr_reserved << "#{k}=#{self.args.delete k}" if self.args.has_key? k
      end

      # if arr_reserved.any?
      #   self.args['merReserved'] = arr_reserved.join('&')
      # else
      #   self.args['merReserved'] ||= ''
      # end

      @param_check.each do |k|
        raise("KEY [#{k}] not set in params given") unless self.args.has_key? k
      end

      # signature
      self.args['signature']  = Service.sign(self.args)
      self
    end
  end
end
