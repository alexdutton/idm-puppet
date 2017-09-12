class idm::broker {
  class { '::rabbitmq':
    service_manage    => false,
    port              => 5672,
    delete_guest_user => true,
  }
}
