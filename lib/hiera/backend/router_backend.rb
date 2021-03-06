require 'hiera/filecache'
require 'yaml'

class Hiera
  class Config
    class << self
      def config
        @config
      end
    end
  end

  module Backend
    class Router_backend
      attr_reader :backends
      attr_accessor :config

      def symbolize_keys(hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v.is_a?(Hash) ? symbolize_keys(v) : v }
      end

      def initialize(cache = nil)
        @cache = cache || Filecache.new
        @backends = {}
        Hiera.debug("[hiera-router] I'm here!")
        self.config = Config.config
        self.config[:hierarchy] = Config[:router][:paths] if Config[:router][:paths]

        if backend_list = Config[:router][:backends]
          Hiera.debug("[hiera-router] Initializing backends: #{backend_list.keys.join(',')}")
          backend_list.each do |backend, backend_config|
            Hiera.debug("[hiera-router] Initializing backend '#{backend}'")
            backend_classname = backend_config['backend_class'] || backend_config[:backend_class] || backend
            full_backend_classname = "#{backend_classname.capitalize}_backend"
            backend_config_override = backend_config['backend_key'] || backend_config[:backend_key] || backend_classname
            Hiera.debug("[hiera-router] Backend class for '#{backend}' will be '#{backend_classname}'")

            backend_config_override_config = Config[backend_config_override.to_sym] || Config[:router][backend_config_override.to_sym] || {}

            backend_config = self.config.clone
            backend_config.delete(:router)
            if backend_config_override_config[:hierarchy]
              backend_config[:hierarchy] = backend_config_override_config[:hierarchy]
            end

            backend_config[:backends] = [backend_classname]
            backend_config[backend_classname.to_sym] = backend_config_override_config
            backend_config = symbolize_keys(backend_config)

            Config.load(backend_config)
            require "hiera/backend/#{full_backend_classname.downcase}"
            backend_inst = Hiera::Backend.const_get(full_backend_classname).new
            Config.load(config)
            @backends[backend.to_sym] = {
              :instance => backend_inst,
              :config => backend_config,
            }
          end
        end

        Hiera.debug("[hiera-router] hiera router initialized")
      end
      def lookup(lookup_key, scope, order_override, resolution_type)
        options = {
          :scope => scope,
          :key => lookup_key,
          :order_override => order_override,
          :resolution_type => resolution_type,
        }

        key_path = split_key(lookup_key)
        key = key_path.shift

        answer = nil
        strategy = resolution_type.is_a?(Hash) ? :hash : resolution_type

        Hiera.debug("[hiera-router] Looking up #{key} in yaml backend (and then return path #{key_path.inspect})")

        Backend.datasources(scope, order_override) do |source|
          yaml_file = Backend.datafile(:router, scope, source, 'yaml') || next

          data = @cache.read(yaml_file, Hash) do |cached_data|
            begin
              Hiera.debug("[hiera-router] Looking + loading data source #{source} ('#{yaml_file}')")
              YAML.load(cached_data) || {}
            rescue
              Hiera.debug("[hiera-router] something wrong with source #{source} '#{yaml_file}' -- returning an empty result")
              {}
            end
          end

          next if data.empty?
          next unless data.include?(key)

          Hiera.debug("[hiera-router] Found #{key} in #{source}")

          new_answer = parse_answer(data[key], scope, options)
          next if new_answer.nil?

          case strategy
          when :array
            raise Exception, "Hiera type mismatch: expected Array and got #{new_answer.class}" unless new_answer.kind_of? Array or new_answer.kind_of? String
            answer ||= []
            answer << new_answer
          when :hash
            raise Exception, "Hiera type mismatch: expected Hash and got #{new_answer.class}" unless new_answer.kind_of? Hash
            answer ||= {}
            answer = Backend.merge_answer(new_answer, answer, resolution_type)
          else
            answer = new_answer
            break
          end
        end

        while e = key_path.shift
          break unless answer
          raise Exception, "Hiera subkey '#{e}' not found" unless answer.include?(e)
          answer = answer[e]
        end

        answer = Backend.resolve_answer(answer, strategy) unless answer.nil?

        return answer
      end

      def split_key(key)
          segments = key.split(/(?:"([^"]+)"|'([^']+)'|([^'".]+))/)
          if segments.empty?
            # Only happens if the original key was an empty string
            ''
          elsif segments.shift == ''
            count = segments.size
            raise yield('Syntax error') unless count > 0

            segments.keep_if { |seg| seg != '.' }
            raise yield('Syntax error') unless segments.size * 2 == count + 1
            segments
         else
            raise yield('Syntax error')
         end
      end

      def recursive_key_from_hash(hash, path)
        focus = hash
        path.each do |key|
          if focus.is_a?(Hash) and focus.include?(key)
            focus = focus[key]
          else
            return nil
          end
        end

        return focus
      end

      def parse_answer(data, scope, options, path = [])
        if data.is_a?(Numeric) or data.is_a?(TrueClass) or data.is_a?(FalseClass)
          return data
        elsif data.is_a?(String)
          return parse_string(data, scope, options, path)
        elsif data.is_a?(Hash)
          answer = {}
          data.each_pair do |key, val|
            interpolated_key = Backend.parse_string(key, scope)
            subpath = path + [interpolated_key]
            answer[interpolated_key] = parse_answer(val, scope, options, subpath)
          end

          return answer
        elsif data.is_a?(Array)
          answer = []
          data.each do |item|
            answer << parse_answer(item, scope, options)
          end

          return answer
        end
      end

      def parse_string(data, scope, options, path = [])
        if match = data.match(/^backend\[([^,]+)(?:,(.*))?\]$/)
          backend_name, backend_parameters = match.captures
          backend_options = options
          backend_options = backend_options.merge(backend_parameters) if backend_parameters
          Hiera.debug("[hiera-router] Calling hiera with '#{backend_name}'...")
          if backend = self.backends[backend_name.to_sym]
            backend_instance = backend[:instance]
            key = split_key(backend_options[:key]).first
            Hiera.debug("[hiera-router] Backend class: #{backend_instance.class.name}")
            Config.load(backend[:config])
            result = backend_instance.lookup(key, backend_options[:scope], nil, backend_options[:resolution_type])
            Config.load(self.config)
          else
            Hiera.warn "Backend '#{backend_name}' was not configured; returning the data as-is."
            result = data
          end
          Hiera.debug("[hiera-router] Call to '#{backend_name}' finished.")
          return recursive_key_from_hash(result, path)
        else
          Backend.parse_string(data, scope)
        end
      end
    end
  end
end
