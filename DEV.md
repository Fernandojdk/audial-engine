#Dev environment

The dev environment uses vagrant and ansible to configure a virtual machine for use in development and testing.

##Local environment setup:

1. install [Vagrant](https://www.vagrantup.com/downloads.html)
2. install [Ansible](http://docs.ansible.com/intro_installation.html)
3. install the Vagrant Landrush plugin (`vagrant plugin install landrush`)
3. clone the repo to a local directory, and cd into it.
4. `vagrant up`
5. `vagrant ssh`, `cd /srv/tfdialer-ahn`, and `bundle exec ahn -` to run the app.
