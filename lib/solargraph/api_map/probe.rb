module Solargraph
  class ApiMap
    class Probe
      class VirtualPin
        attr_reader :return_type
        def initialize return_type
          @return_type = return_type
        end
        def namespace
          @namespace ||= TypeMethods.extract_namespace(@return_type)
        end
      end

      include TypeMethods

      # @return [Solargraph::ApiMap]
      attr_reader :api_map

      def initialize api_map
        @api_map = api_map
      end

      # Get all matching pins for the signature.
      #
      # @return [Array<Pin::Base>]
      def infer_signature_pins signature, context_pin, locals
        return [] if signature.nil? or signature.empty?
        base, rest = signature.split('.', 2)
        return infer_word_pins(base, context_pin, locals) if rest.nil?
        pins = infer_word_pins(base, context_pin, locals).map do |pin|
          next pin unless pin.return_type.nil?
          type = resolve_pin_type(pin)
          VirtualPin.new(type)
        end
        return [] if pins.empty?
        return smart_find_def

        # rest = rest.split('.')
        # last = rest.pop
        # rest.each do |meth|
        #   found = nil
        #   pins.each do |pin|
        #     found = infer_method_name_pins(meth, pin)
        #     next if found.empty?
        #     pins = found
        #     break
        #   end
        #   return [] if found.nil?
        # end
        # pins.each do |pin|
        #   found = infer_method_name_pins(last, pin)
        #   return found unless found.empty?
        # end
        # []
      end

      def smart_find_def(method_name, namespace)
        namespace = if context_pin.kind == Pin::NAMESPACE
              pin.path
            else
              pin.namespace
            end

        pin = @api_map.defs[[signature, namespace]]
        type = resolve_pin_type(pin)
      end

      # Get the return type for the signature.
      #
      # @return [String]
      def infer_signature_type signature, context_pin, locals
        pins = infer_signature_pins(signature, context_pin, locals)
        pins.each do |pin|
          type = resolve_pin_type(pin)
          return qualify(type, pin.named_context) unless type.nil?
        end
        nil
      end

      private

      # Word search is ALWAYS internal
      def infer_word_pins word, context_pin, locals
        return [] if word.empty?
        lvars = locals.select{|pin| pin.name == word}
        return lvars unless lvars.empty?
        return api_map.get_global_variable_pins.select{|pin| pin.name == word} if word.start_with?('$')
        namespace, scope = extract_namespace_and_scope_from_pin(context_pin)
        return api_map.pins.select{|pin| word_matches_context?(word, namespace, scope, pin)} if variable_name?(word)
        result = []
        result.concat api_map.get_path_suggestions(word)
        result.concat api_map.get_methods(namespace, scope: scope, visibility: [:public, :private, :protected]).select{|pin| pin.name == word} unless word.include?('::')
        result.concat api_map.get_constants('', namespace).select{|pin| pin.name == word}
        result
      end

      # Method name search is external by default
      # @param method_name [String]
      # @param context_pin [Solargraph::Pin::Base]
      def infer_method_name_pins method_name, context_pin, internal = false
        relname, scope = extract_namespace_and_scope(context_pin.return_type)
        namespace = api_map.qualify(relname, context_pin.namespace)
        visibility = [:public]
        visibility.push :protected, :private if internal
        result = api_map.get_methods(namespace, scope: scope, visibility: visibility).select{|pin| pin.name == method_name}
        # @todo This needs more rules. Probably need to update YardObject for it.
        return result if result.empty?
        return result unless method_name == 'new' and result.first.path == 'Class#new'
        result.unshift virtual_new_pin(result.first, context_pin)
        result
      end

      # Word and context matching rules for ApiMap source pins.
      #
      # @return [Boolean]
      def word_matches_context? word, namespace, scope, pin
        return false unless word == pin.name
        return true if pin.kind == Pin::NAMESPACE and pin.path == namespace and scope == :class
        return true if pin.kind == Pin::METHOD and pin.namespace == namespace and pin.scope == scope
        # @todo Handle instance variables, class variables, etc. in various ways
        pin.namespace == namespace and pin.scope == scope
      end

      # Fully qualify the namespace in a type.
      #
      # @return [String]
      def qualify type, context
        rns, rsc = extract_namespace_and_scope(type)
        res = api_map.qualify(rns, context)
        return res if rsc == :instance
        type.sub(/<#{rns}>/, "<#{res}>")
      end

      # Extract a namespace and a scope from a pin. For now, the pin must
      # be either a namespace, a method, or a block.
      #
      # @return [Array] The namespace (String) and scope (Symbol).
      def extract_namespace_and_scope_from_pin pin
        return [pin.namespace, pin.scope] if pin.kind == Pin::METHOD
        return [pin.path, :class] if pin.kind == Pin::NAMESPACE
        # @todo Is :class appropriate for blocks?
        return [pin.namespace, :class] if pin.kind == Pin::BLOCK
        raise "Unable to extract namespace and scope from #{pin.path}"
      end

      # Determine whether or not the word represents a variable. This method
      # is used to keep the probe from performing unnecessary constant and
      # method searches.
      #
      # @return [Boolean]
      def variable_name? word
        word.start_with?('@') or word.start_with?('$')
      end

      # Create a `new` pin to facilitate type inference. This is necessary for
      # classes from YARD and classes in the namespace that do not have an
      # `initialize` method.
      #
      # @return [Pin::Method]
      def virtual_new_pin new_pin, context_pin
        pin = Pin::Method.new(new_pin.location, new_pin.namespace, new_pin.name, new_pin.docstring, new_pin.scope, new_pin.visibility, new_pin.parameters)
        # @todo Smelly instance variable access.
        pin.instance_variable_set(:@return_type, context_pin.path)
        pin
      end

      def resolve_pin_type pin
        pin.return_type
        return pin.return_type unless pin.return_type.nil?
        return resolve_block_parameter(pin) if pin.kind == Pin::BLOCK_PARAMETER
        return resolve_variable(pin) if pin.variable?
        nil
      end

      def resolve_block_parameter pin
        return pin.return_type unless pin.return_type.nil?
        signature = pin.block.receiver
        # @todo Not sure if assuming the first pin is good here
        meth = @api_map.probe.infer_signature_pins(signature, pin.block, []).first
        return nil if meth.nil?
        if (Solargraph::CoreFills::METHODS_WITH_YIELDPARAM_SUBTYPES.include?(meth.path))
          base = signature.split('.')[0..-2].join('.')
          return nil if base.nil? or base.empty?
          # @todo Not sure if assuming the first pin is good here
          bmeth = @api_map.probe.infer_signature_pins(base, pin.block, []).first
          return nil if bmeth.nil?
          subtypes = get_subtypes(bmeth.return_type)
          return subtypes[0]
        else
          unless meth.docstring.nil?
            yps = meth.docstring.tags(:yieldparam)
            unless yps[pin.index].nil? or yps[pin.index].types.nil? or yps[pin.index].types.empty?
              return yps[pin.index].types[0]
            end
          end
        end
        nil
      end

      def resolve_variable(pin)
        return nil if pin.nil_assignment?
        # @todo Do we need the locals here?
        return infer_signature_type(pin.signature, pin.context, [])
      end

      def get_subtypes type
        return nil if type.nil?
        match = type.match(/<([a-z0-9_:, ]*)>/i)
        return [] if match.nil?
        match[1].split(',').map(&:strip)
      end
    end
  end
end
