Vagrant.configure("2") do |config|
  config.vm.box = 'ubuntu/trusty64'

  config.vm.network :private_network, type: 'dhcp'
  config.vm.hostname = "tfdialer.vagrant.dev"
  config.landrush.enabled = true

  config.vm.synced_folder ".", "/srv/tfdialer_ahn"
  config.vm.synced_folder "../tfdialer_api", "/srv/tfdialer_api" if File.exist?(File.dirname(__FILE__) + '/../tfdialer_api')

  config.vm.provider :virtualbox do |vb|
    vb.name = "tfdialer_devbox"
    vb.memory = 1024
    vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
  end

  config.vm.provision "ansible" do |ansible|
    ansible.playbook = "provisioning/devbox.yml"
  end
end
