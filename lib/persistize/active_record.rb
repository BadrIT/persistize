module Persistize
  mattr_accessor :performant
  self.performant = true

  module ActiveRecord
    module ClassMethods
      def persistize(*args)
        options = args.extract_options!

        performant = {:performant => ::Persistize.performant}.merge(options)[:performant]

        args.each do |method|
          attribute = method.to_s.sub(/\?$/, '')

          original_method = :"_unpersistized_#{attribute}"
          update_method   = :"_update_#{attribute}"

          class_eval <<-RUBY, __FILE__, __LINE__ + 1
            alias #{original_method} #{method}                    # alias _unpersistized_full_name full_name
                                                                  #
            def #{method}                                         # def full_name
              if new_record? || changed?                          #   if new_record? || changed?
                #{original_method}                                #     _unpersistized_full_name
              else                                                #   else
                self[:#{attribute}]                               #     self[:full_name]
              end                                                 #   end
            end                                                   # end
                                                                  #
            before_create :#{update_method}                       # before_create :_update_full_name
            before_update :#{update_method}, :if => :changed?     # before_update :_update_full_name, :if => :changed?
                                                                  #
            def #{update_method}                                  # def _update_full_name
              self[:#{attribute}] = #{original_method}            #   self[:full_name] = _unpersistized_full_name
              true # return true to avoid canceling the save      #   true
            end                                                   # end
                                                                  #
            def #{update_method}!                                 # def _update_full_name!
              if #{performant}                                    #   if performant
                new_#{attribute} = #{original_method}             #     new_full_name = _unpersistized_full_name
                return if new_#{attribute} == self[:#{attribute}] #     return if new_full_name == self[:full_name]
                update_attribute :#{attribute}, new_#{attribute}  #     update_attribute :full_name, new_full_name
              else                                                #   else
                #{update_method}                                  #     _update_full_name
                save! if #{attribute}_changed?                    #     save! if full_name_changed?
              end                                                 #   end
            end                                                   # end
          RUBY

          if options && options[:depending_on]
            if options[:depending_on].is_a?(Array) || options[:depending_on].is_a?(Symbol)
              dependencies = [options[:depending_on]].flatten
              dependencies.each do |dependency|
                generate_callback(reflections[dependency.to_s], update_method)
              end
            
            elsif options[:depending_on].is_a? Hash
              dependencies = options[:depending_on]
              dependencies.each do |key, value|                   # value => Hash Contain three <Proc...> for save, destroy and when
                generate_callback(reflections[key.to_s], update_method, value)
              end
            end
          end

        end
      end

      private

      def generate_callback(association, update_method, conditional_block=nil)
        callback_name = :"#{update_method}_in_#{self.to_s.underscore.gsub(/\W/, '_')}_callback"
        association_type = "#{association.macro}#{'_through' if association.through_reflection}"
        generate_method = :"generate_#{association_type}_callback"
        unless respond_to?(generate_method, true)
          raise "#{association_type} associations are not supported by persistize"
        end

        # true by default
        conditional_block ||= {}
        conditional_block[:when] ||= Proc.new{|_a,_b| true}
        conditional_block[:save] ||= Proc.new{|_a,_b| true}
        conditional_block[:destroy] ||= Proc.new{|_a,_b| true}

        blocks = if association.klass.class_variable_defined?(:@@_persistize_conditional_block)
          association.klass.class_variable_get(:@@_persistize_conditional_block)
        else
          {}
        end
        blocks["_proc_#{callback_name}"] = conditional_block
        association.klass.class_variable_set(:@@_persistize_conditional_block, blocks)

        unless association.klass.instance_methods.include?(:apply_persistize?)
          association.klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def apply_persistize?(persistized_obj, depending_on_obj, callback_name)
              conditional_block = @@_persistize_conditional_block["_proc_#{callback_name}"]
              if conditional_block[:when].call(persistized_obj, depending_on_obj)
                apply_destroy = destroyed? && conditional_block[:destroy].call(persistized_obj, depending_on_obj)
                apply_save = !destroyed? && conditional_block[:save].call(persistized_obj, depending_on_obj)
                return apply_destroy || apply_save
              else
                return false
              end
            end
          RUBY
        end

        send(generate_method, association, update_method, callback_name)
      end

      def generate_has_many_callback(association, update_method, callback_name)
        association.klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{callback_name}                                                # def _update_completed_in_project_callback
            return true unless parent_id = self[:#{association.foreign_key}]  #   return true unless parent_id = self[:project_id]
            parent = #{self.name}.find(parent_id)                             #   parent = Project.find(parent_id)
            if apply_persistize?(parent, self, "#{callback_name}")
              parent.#{update_method}! 
            end
          end                                                                 # end
          after_save :#{callback_name}                                        # after_save :_update_completed_in_project_callback
          after_destroy :#{callback_name}                                     # after_destroy :_update_completed_in_project_callback
        RUBY
      end

      alias_method :generate_has_one_callback, :generate_has_many_callback        # implementation is just the same :)

      def generate_has_many_through_callback(association, update_method, callback_name)
        association.klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{callback_name}                                                                                # def _update_completed_in_person_callback
            return true unless through_id = self[:#{association.through_reflection.association_foreign_key}]  #   return true unless through_id = self[:project_id]
            through = #{association.through_reflection.class_name}.find(through_id)                           #   through = Project.find(through_id)
            return true unless parent_id = through[:#{association.through_reflection.foreign_key}]            #   return true unless parent_id = self[:person_id]
            parent = #{self.name}.find(parent_id)                                                             #   parent = Person.find(person_id)
            if apply_persistize?(parent, self, "#{callback_name}")
              parent.#{update_method}!                                                                        #   parent._update_completed!
            end
          end                                                                                                 # end
          after_save :#{callback_name}                                                                        # after_save :_update_completed_in_person_callback
          after_destroy :#{callback_name}                                                                     # after_destroy :_update_completed_in_person_callback
        RUBY
      end

      def generate_belongs_to_callback(association, update_method, callback_name)
        association.klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{callback_name}                                               # def _update_project_name_in_task_callback
            children = #{self.name}.where({:#{association.foreign_key} => id}) #   children = Task.where({:project_id => id})
            children.each do |child|
              if apply_persistize?(child, self, "#{callback_name}")
                child.#{update_method}!
              end
            end
          end                                                                # end
          after_save :#{callback_name}                                       # after_save :_update_project_name_in_task_callback
          after_destroy :#{callback_name}                                    # after_destroy :_update_project_name_in_task_callback
        RUBY
      end

    end
  end
end
