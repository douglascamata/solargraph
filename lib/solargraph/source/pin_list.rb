class PinList < Array

	autoload :BaseVariable, 'solargraph/pin/base_variable'

	attr_reader :defs

	def initialize
		@defs = {}
	end

	def push(pin=nil)
		return self if pin.nil?
		new_array = super
		defs[[pin.name, pin.namespace]] = pin if pin.kind_of?(Solargraph::Pin::BaseVariable)
		new_array
	end
end