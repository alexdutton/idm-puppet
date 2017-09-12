define idm::app (
  $vcs_url,
  $app_package,
  $server_name,
  $flower_port,
  $additional_environment = [],
  $wsgi_app = true,
  $solr_core = false,
) {
  $home = "/srv/idm-${name}"
  $user = "idm_${name}"
  $repo = "${home}/repo"
  $venv = "${home}/venv"
  $wsgi = "${home}/app.wsgi"
  $static_root = "${home}/static"
  $manage_py = "${home}/manage.py"
  $python = "${venv}/bin/python"
  $celery_vhost = "idm-${name}-celery"
  $env_file = "$home/env.sh"
  $keytab = "$home/krb5.keytab"
  $systemd_celery_service = "/etc/systemd/system/idm-$name-celery.service"
  $systemd_flower_service = "/etc/systemd/system/idm-$name-flower.service"
  $systemd_broker_task_consumer_service = "/etc/systemd/system/idm-$name-broker-task-consumer.service"

  $fixture = "$home/fixture.yaml"

  # Principal names
  $client_principal_name = "api/$server_name"
  $kadmin_principal_name = "$server_name/admin"

  # Secrets
  $django_secret_key = hiera("idm::${name}::secret_key")
  $amqp_password = hiera("idm::${name}::amqp_password")

  # Other hiera values
  $django_debug = hiera("idm::${name}::debug", false) ? { true => "on", default => "off" }

  $application_environment = [
    "CELERY_BROKER_URL=amqp://${user}:${amqp_password}@localhost/$celery_vhost",
    "DJANGO_ALLOWED_HOSTS=$server_name",
    "DJANGO_DEBUG=$django_debug",
    "DJANGO_SETTINGS_MODULE=${app_package}.settings",
    "DJANGO_SECRET_KEY=$django_secret_key",
    "DJANGO_STATIC_ROOT=$static_root",
    "DJANGO_EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend",
    "BROKER_SSL=no",
    "BROKER_USERNAME=$user",
    "BROKER_PASSWORD=$amqp_password",
    "KRB5_KTNAME=$keytab",
    "KRB5_CLIENT_KTNAME=$keytab",
    "CELERYD_NODES=4",
    "CELERYD_PID_FILE=$home/celery.pid",
    "CELERYD_LOG_FILE=/var/log/idm-${name}-celery.log",
    "CELERYD_LOG_LEVEL=info",
    "REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt",
    "CLIENT_PRINCIPAL_NAME=$client_principal_name",
  ] + ($name ? {
    auth => [
      "KADMIN_PRINCIPAL_NAME=$kadmin_principal_name",
    ],
    default => [],
  }) + ($solr_core ? {
    true => [
      "HAYSTACK_SOLR_URL=http://localhost:8080/solr/idm-$name",
    ],
    default => [],
  })+ $additional_environment + hiera_array("idm::${name}::additional_environment", [])

  user {
    $user:
      ensure => present,
      home => $home,
      managehome => true;
  }

  rabbitmq_user { $user:
    password => $amqp_password,
  }

  rabbitmq_vhost { $celery_vhost:
    ensure => present,
  }

  rabbitmq_user_permissions { "${user}@/":
    configure_permission => "idm\\.${name}\\..*",
    read_permission      => '.*',
    write_permission     => "idm\\.${name}\\..*",
  }

  rabbitmq_user_permissions { "${user}@${celery_vhost}":
    configure_permission => '.*',
    read_permission      => '.*',
    write_permission     => '.*',
  }

  vcsrepo { $repo:
    ensure => present,
    provider => git,
    source => $vcs_url,
  }

  apache::vhost {
    "idm-${name}-non-ssl":
      servername => $server_name,
      port => 80,
      docroot => "$home/docroot",
      redirect_status => 'permanent',
      redirect_dest   => "https://${server_name}/";
    "idm-${name}-ssl":
      servername => $server_name,
      port => 443,
      docroot => "$home/docroot",
      ssl => true,
      ssl_cert => $idm::web::ssl_cert,
      ssl_key => $idm::web::ssl_key,
      wsgi_daemon_process => ($wsgi_app ? {
        true => "idm-${name}",
        default => undef,
      }),
      wsgi_daemon_process_options => {
        processes => '2',
        threads => '15',
        display-name => '%{GROUP}',
        python-home => $venv,
        user => $user,
        group => $user,
      },
      wsgi_process_group => ($wsgi_app ? {
        true => "idm-${name}",
        default => undef,
      }),
      wsgi_script_aliases  => ($wsgi_app ? {
        true => { '/' => $wsgi },
        default => undef,
      }),
      aliases => [ { alias => '/static', path => $static_root } ],
      directories => [
        { path => $static_root, require => "all granted" },
        {
          provider => "location",
          path => "/api/",
          auth_type => "GSSAPI",
          require => "valid-user",
          custom_fragment => "
              GssapiCredStore keytab:${idm::web::http_keytab}
          ",
        },
      ] + ($name ? {
        "auth" => [{
          provider => "locationmatch",
          path => "/openid/(token|userinfo)/",
          custom_fragment => "WSGIPassAuthorization On",
        }],
        default => [],
      }),
      proxy_pass => [
        { path => '/flower/', url => "http://localhost:$flower_port/"}
      ],
      require => Exec["create-ssl-cert"];
  }

  anchor {"idm-${name}-ready":
    require => Exec["idm-${name}-install-requirements"]
  }

  exec {
    "idm-${name}-create-virtualenv":
      unless  => "/usr/bin/test -d $venv",
      command => "/usr/bin/virtualenv $venv --python=/usr/bin/python3",
      require => Package["python-virtualenv"];
    "idm-${name}-install-requirements":
      command   => "$venv/bin/pip install -r $repo/requirements.txt",
      require   => Vcsrepo[$repo],
      refreshonly => true,
      subscribe => Exec["idm-${name}-create-virtualenv"];
    "idm-${name}-install-additional":
      command   => "$venv/bin/pip install flower",
      require   => Vcsrepo[$repo],
      refreshonly => true,
      subscribe => Exec["idm-${name}-create-virtualenv"];
  }

  if ($wsgi_app) {
    exec {
      "idm-${name}-collectstatic":
        command => "$manage_py collectstatic --no-input",
        require => [Exec["idm-${name}-install-requirements"],
                    File[$manage_py],
                    Class["rabbitmq"]];
      "idm-${name}-migrate":
        command => "$manage_py migrate",
        user    => $user,
        require => [Exec["idm-${name}-install-requirements"],
                    Postgresql::Server::Database[$user],
                    File[$manage_py],
                    Class["rabbitmq"]],
        before => Anchor["idm-${name}-ready"];
      "idm-${name}-initial-fixtures":
        command => "$manage_py loaddata initial",
        returns => [0, 1], # Don't worry if there are actually no such fixtures
        user    => $user,
        require => Exec["idm-${name}-migrate"],
        before => Anchor["idm-${name}-ready"];
      "idm-${name}-load-fixture":
        command   => "$manage_py loaddata $fixture",
        user      => $user,
        require   => Exec["idm-${name}-migrate"],
        subscribe => File[$fixture],
        refreshonly => true,
        before => Anchor["idm-${name}-ready"];
    }

    # Fixtures require idm-auth to talk to idm-core, so make sure Apache is all set up first.
    Apache::Vhost <| |> -> Exec["idm-${name}-load-fixture"]

    file {
      $wsgi:
        content => template('idm/env.py.erb', 'idm/app.wsgi.erb'),
        notify  => Apache::Vhost["idm-${name}-ssl"];
      $fixture:
        content => template("idm/fixture-$name.yaml.erb");
    }
  }

  if ($name == "auth") {
    exec {
    "idm-${name}-create-rsa-key":
      command => "$manage_py creatersakey",
      user => $user,
      unless => "/usr/bin/test \"$(/usr/bin/psql -c 'select count(*) from oidc_provider_rsakey' -At)\" != \"0\"",
      require => Exec["idm-${name}-migrate"],
      provider => shell;
    }
  }

  file {
    $manage_py:
      content => template('idm/venv-python-hashbang.erb', 'idm/env.py.erb', 'idm/manage.py.erb'),
      mode => '755';
    $static_root:
      ensure => directory;
    $systemd_celery_service:
      content => template("idm/celery.service.erb");
    $systemd_flower_service:
      content => template("idm/flower.service.erb");
    $systemd_broker_task_consumer_service:
      content => template("idm/broker-task-consumer.service.erb");
    $env_file:
      content => template("idm/env.sh.erb");
    "/var/log/idm-${name}-celery.log":
      ensure => present,
      content => '',
      replace => 'no',
      owner => $user,
      group => $user,
      mode => "600";
  }

  service {
    "idm-$name-celery":
      ensure => running,
      require => [File[$systemd_celery_service], Anchor["idm-${name}-ready"]];
    "idm-$name-flower":
      ensure => running,
      require => [File[$systemd_flower_service], Anchor["idm-${name}-ready"]];
    "idm-$name-broker-task-consumer":
      ensure => running,
      require => [File[$systemd_broker_task_consumer_service], Anchor["idm-${name}-ready"]];
  }

  postgresql::server::database { $user:
    owner => $user,
  }

  postgresql::server::role { $user:
  }

  $principals = [
    $client_principal_name,
  ] + ($name ? {
    auth => [
      $kadmin_principal_name,
    ],
    default => [],
  })

  idm::kerberos::keytab {
    $keytab:
      owner => $user,
      group => $user,
      principals => $principals
  }

  if ($solr_core) {
    $schema_xml = "$home/solr-schema.xml"

    exec { "idm-$name-build-solr-schema":
      command => "$manage_py build_solr_schema > $schema_xml",
      user    => $user,
      creates => $schema_xml,
      require => Anchor["idm-${name}-ready"];
    }

    idm::solr::core {
      "idm-$name":
        schema_xml => $schema_xml,
    }

    Exec["idm-${name}-install-requirements"] -> Exec["idm-$name-build-solr-schema"] -> Idm::Solr::Core["idm-$name"]

  }
}