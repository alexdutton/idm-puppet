# idm-puppet, a Puppet module for an IdM

This puppet module installs and configures [the proof-of-concept IdM](https://github.com/alexsdutton/idm).


## Getting started

First, install Puppet (`apt-get install puppet`) and then follow the instructions for setting up
[librarian-puppet](https://github.com/voxpupuli/librarian-puppet). In summary:

```shell
apt-get install librarian-puppet git pwgen
cd /usr/share/puppet
librarian-puppet init
```

Your `Puppetfile` (`/usr/share/puppet/Puppetfile`) should contain something like:

```
forge 'https://forgeapi.puppetlabs.com'

mod 'alexsdutton-idm', :git => 'https://github.com/alexsdutton/idm-puppet.git'
```

You'll need to make sure there's no `metadata` line.

This puppet module uses hiera to provide deployment-specific configuration data. Edit
`/etc/puppet/code/hiera/common.yaml` to contain:

```yaml
idm::core::secret_key: [secret]
idm::auth::secret_key: [secret]
idm::card::secret_key: [secret]
idm::integration::secret_key: [secret]

idm::core::amqp_password: [secret]
idm::auth::amqp_password: [secret]
idm::card::amqp_password: [secret]
idm::integration::amqp_password: [secret]

idm::core::debug: true
idm::auth::debug: true
idm::card::debug: true

idm::kerberos::realm: IDM-DEMO.EXAMPLE.ORG
idm::kerberos::master_password: [secret]

idm::core::oidc::client_id: [secret]
idm::core::oidc::client_secret: [secret]

idm::card::oidc::client_id: [secret]
idm::card::oidc::client_secret: [secret]

idm::auth::additional_environment:
# To use social authentication, get client credentials for your deployment from each service and put them in here:
#  - SOCIAL_AUTH_TWITTER_KEY=[...]
#  - SOCIAL_AUTH_TWITTER_SECRET=[...]
#  - SOCIAL_AUTH_GOOGLE_OAUTH2_KEY=[...]
#  - SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET=[...]
#  - SOCIAL_AUTH_GITHUB_KEY=[...]
#  - SOCIAL_AUTH_GITHUB_SECRET=[...]
#  - SOCIAL_AUTH_FACEBOOK_KEY=[...]
#  - SOCIAL_AUTH_FACEBOOK_SECRET=[...]
  - SMTP_SERVER=smtp.ox.ac.uk
  - DJANGO_ADMINS=First Last <someone@example.org>

# Firewall rules
firewall::allow_ssh_from: ['163.1.124.0/23', '129.67.100.0/22']
firewall::allow_http_from: ['163.1.0.0/16', '129.67.0.0/16']


idm::core::server_name: idm-demo-core.it.ox.ac.uk
idm::card::server_name: idm-demo-card.it.ox.ac.uk
idm::auth::server_name: idm-demo-auth.it.ox.ac.uk
idm::integration::server_name: idm-demo-integration.it.ox.ac.uk

idm::web:self_signed_cert: true
```

You'll want to replace each `[secret]` with a randomly-generated secret (using e.g. `pwgen 32`). You can do this with the following script:

```bash
while grep "\[secret\]" /etc/puppet/code/hiera/common.yaml; do
    sed -i "0,/\[secret]/{s/\[secret\]/$(pwgen 32 1)/}" /etc/puppet/code/hiera/common.yaml ;
done
```

Finally, create your main Puppet manifest, `/etc/puppet/manifests/site.pp`:

```puppet
node default {
    include idm
}
```

When this is all done, run:

```shell
cd /usr/share/puppet/
librarian-puppet install
puppet apply /etc/puppet/manifests/site.pp
```

(`librarian-puppet` needs to be run in `/usr/share/puppet/` as it works relative to the current directory)

And on subsequent runs:

```shell
cd /usr/share/puppet/
librarian-puppet update alexsdutton-idm
puppet apply /etc/puppet/manifests/site.pp
```

If it doesn't succeed first time, create an issue with the error, and try it another time or two.

You'll want to configure DNS (or your VM host's `/etc/hosts` file) to resolve the server names given in the hiera data
above to the machine on which you've installed the IdM.
