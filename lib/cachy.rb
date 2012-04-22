module Cachy
  extend ActiveSupport::Concern

  def self.set_cache_config(cache_config)
    @cache_config = cache_config
  end

  def self.cache_config
    @cache_config ||= { :version => 1 }
  end

  def self.set_cache(cache)
    @cache = cache
  end

  def self.cache
    @cache ||= Rails.cache
  end

  def self.digest(key, options = {})
    key = key.map { |v| "#{v}" }.join(':') if key.is_a?(::Array)
    key = key.sort_by { |k, v| "#{k}" }.join(':') if key.is_a?(::Hash)
    key = "#{key}" unless key.is_a?(::String)

    key = "version:#{cache_config[:version]}:#{key}" unless options[:no_version]
    key = "locale:#{I18n.locale}:#{key}" unless options[:no_locale]
    key = Digest::SHA1.hexdigest(key) unless options[:no_sha]

    key
  end

  def self.cache_option_keys
    @cache_option_keys ||= [:expires_in]
  end

  def self.digest_option_keys
    @digest_option_keys ||= [:no_version, :no_locale, :no_sha]
  end

  module ClassMethods
    def set_cachy_cache(cachy_cache)
      @cachy_cache = cachy_cache
    end

    def cachy_cache
      @cachy_cache ||= ::Cachy.cache
    end

    def set_cachy_options(options)
      @cachy_options = cachy_options.merge(options)
    end

    def cachy_options
      @cachy_options ||= { :expires_in => 1.day, :no_locale => true }
    end

    def caches_method(name, options = {}, &block)
      class_key = "#{self.name}:#{name}"

      name_no_cache = "#{name}_no_cache"

      options.reverse_merge!(cachy_options)

      block_if = options[:if]
      block_with_key = options[:with_key] || :id # id of the object is the default key.
      block_after_load = options[:after_load]

      class_eval do
        define_method "#{name}_via_cache" do |*args, &block|
          if block_with_key.is_a?(Proc)
            cache_key = block_with_key.call(self, *args)
          else
            cache_key = self.send(block_with_key)
          end

          cache_key = ::Cachy.digest(cache_key, options.slice(*::Cachy.digest_option_keys))

          variable = "@cachy_#{name}_#{cache_key}"
          unless instance_variable_defined?(variable)
            object = if block_if && block_if.call(self, *args) == false
              send(name, *args)
            else
              if defined?(Rails) && !Rails.env.production?
                Rails.logger.info "#{class_key}:#{cache_key}"
                Rails.logger.info options.slice(*::Cachy.cache_option_keys).inspect
              end

              begin
                obj = self.class.cachy_cache.fetch("#{class_key}:#{cache_key}", options.slice(*::Cachy.cache_option_keys)) do
                  o = send(name, *args)
                  block && block.call(o)
                  o
                end

                # In development, classes are not cached.
                if object.frozen? && object.is_a?(::String) && object =~ /ActiveSupport::Cache::Entry/
                  object = Marshal.load(object).value
                end
              rescue ArgumentError => error
                lazy_load ||= Hash.new { |hash, hash_key| hash[hash_key] = true; false }

                if error.to_s[/undefined class|referred/] && !lazy_load[error.to_s.split.last.constantize]
                  retry
                else
                  raise error
                end
              end
            end

            instance_variable_set(variable, object)
          end

          instance_variable_get(variable)
        end

        define_method "clear_cache_#{name}" do |*args|
          if block_with_key.is_a?(Proc)
            cache_key = block_with_key.call(self, *args)
          else
            cache_key = self.send(block_with_key)
          end

          cache_key = ::Cachy.digest(cache_key, options.slice(*::Cachy.digest_option_keys))

          variable = "@cachy_#{name}_#{cache_key}"
          remove_instance_variable(variable) if instance_variable_defined?(variable)

          self.class.cachy_cache.delete("#{class_key}:#{cache_key}")
        end
      end

    end

    def caches_methods(*names)
      options = names.extract_options!
      names.each do |name|
        caches_method(name, options)
      end
    end

    def caches_class_method(name, options = {}, &block)
      options.reverse_merge!(cachy_options)

      block_if = options[:if]
      block_with_key = options[:with_key]
      block_after_load = options[:after_load]

      class_key = "#{self.name}:class:#{name}"
      (class << self; self; end).instance_eval do
        define_method "#{name}_via_cache" do |*args, &block|
          if block_with_key
            cache_key = block_with_key.call(*args)
          else
            cache_key = *args
          end

          cache_key = ::Cachy.digest(cache_key, options.slice(*::Cachy.digest_option_keys))

          object = if block_if && block_if.call(*args) == false
            send(name, *args)
          else
            if defined?(Rails) && !Rails.env.production?
              Rails.logger.info "#{class_key}:#{cache_key}"
              Rails.logger.info options.slice(*::Cachy.cache_option_keys).inspect
            end

            begin
              obj = cachy_cache.fetch("#{class_key}:#{cache_key}", options.slice(*::Cachy.cache_option_keys)) do
                o = send(name, *args)
                block && block.call(o)
                o
              end

              # In development, classes are not cached.
              if object.frozen? && object.is_a?(::String) && object =~ /ActiveSupport::Cache::Entry/
                object = Marshal.load(object).value
              end
            rescue ArgumentError => error
              lazy_load ||= Hash.new { |hash, hash_key| hash[hash_key] = true; false }

              if error.to_s[/undefined class|referred/] && !lazy_load[error.to_s.split.last.constantize]
                retry
              else
                raise error
              end
            end
          end


          object
        end

        define_method "clear_cache_#{name}" do |*args|
          if block_with_key
            cache_key = block_with_key.call(*args)
          else
            cache_key = *args
          end

          cache_key = ::Cachy.digest(cache_key, options.slice(*::Cachy.digest_option_keys))

          cachy_cache.delete("#{class_key}:#{cache_key}")
        end
      end

    end

    def caches_class_methods(*names, &block)
      options = names.extract_options!
      names.each do |name|
        caches_class_method(name, options)
      end
    end
  end

end