class idm::firewall {
   class { 'firewall': }

   stage { 'fw_pre':  before  => Stage['main']; }
   stage { 'fw_post': require => Stage['main']; }

   class { 'idm::firewall::pre':
     stage => 'fw_pre',
   }

   class { 'idm::firewall::post':
     stage => 'fw_post',
   }

  resources { "firewall":
     purge => true
  }
}
