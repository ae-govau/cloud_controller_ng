require 'actions/services/synchronous_orphan_mitigate'
require 'actions/services/locks/lock_check'
require 'repositories/service_binding_event_repository'

module VCAP::CloudController
  class ServiceBindingCreate
    class InvalidServiceBinding < StandardError; end
    class ServiceInstanceNotBindable < InvalidServiceBinding; end
    class ServiceBrokerInvalidSyslogDrainUrl < InvalidServiceBinding; end
    class VolumeMountServiceDisabled < InvalidServiceBinding; end
    class SpaceMismatch < InvalidServiceBinding; end

    include VCAP::CloudController::LockCheck

    def initialize(user_audit_info)
      @user_audit_info = user_audit_info
    end

    def create(app, service_instance, message, volume_mount_services_enabled, accepts_incomplete)
      raise ServiceInstanceNotBindable unless service_instance.bindable?
      raise VolumeMountServiceDisabled if service_instance.volume_service? && !volume_mount_services_enabled
      raise SpaceMismatch unless bindable_in_space?(service_instance, app.space)
      raise_if_locked(service_instance)

      binding = ServiceBinding.new(
        service_instance: service_instance,
        app:              app,
        credentials:      {},
        type:             message.type,
        name:             message.name,
      )
      raise InvalidServiceBinding.new(binding.errors.full_messages.join(' ')) unless binding.valid?

      client = VCAP::Services::ServiceClientProvider.provide(instance: service_instance)

      binding_result = request_binding_from_broker(client, binding, message.parameters, accepts_incomplete)

      binding.set(binding_result[:binding])

      begin
        if binding_result[:async]
          binding.save_with_new_operation({ type: 'create', state: 'in progress', broker_provided_operation: binding_result[:operation] })
          last_operation_result = client.fetch_service_binding_last_operation(binding)
          binding.last_operation.update(last_operation_result[:last_operation])
        else
          binding.save
        end

        Repositories::ServiceBindingEventRepository.record_create(binding, @user_audit_info, message.audit_hash)
      rescue => e
        logger.error "Failed to save state of create for service binding #{binding.guid} with exception: #{e}"
        mitigate_orphan(binding)
        raise e
      end

      binding
    end

    private

    def request_binding_from_broker(client, service_binding, parameters, accepts_incomplete)
      client.bind(service_binding, parameters, accepts_incomplete).tap do |response|
        response.delete(:route_service_url)
      end
    end

    def mitigate_orphan(binding)
      orphan_mitigator = SynchronousOrphanMitigate.new(logger)
      orphan_mitigator.attempt_unbind(binding)
    end

    def bindable_in_space?(service_instance, app_space)
      service_instance.space == app_space || service_instance.shared_spaces.include?(app_space)
    end

    def logger
      @logger ||= Steno.logger('cc.action.service_binding_create')
    end
  end
end
