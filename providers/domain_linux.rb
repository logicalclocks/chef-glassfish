#
# Copyright:: Peter Donald
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

provides :glassfish_domain, os: 'linux'

include Chef::Asadmin

def domain_dir_arg
  "--domaindir #{node['glassfish']['domains_dir']}"
end

def service_name
  "glassfish-#{new_resource.domain_name}"
end

action :create do
  if new_resource.system_group != node['glassfish']['group']
    group new_resource.system_group do
    end
  end

  if new_resource.system_user != node['glassfish']['user'] && new_resource.system_user != 'root'
    user new_resource.system_user do
      comment "GlassFish #{new_resource.domain_name} Domain"
      gid new_resource.system_group
      home "#{node['glassfish']['domains_dir']}/#{new_resource.domain_name}"
      shell '/bin/bash'
      system true
    end
  end

  requires_authbind = new_resource.port < 1024 || new_resource.admin_port < 1024 || new_resource.https_port < 1024

  service service_name do
    supports start: true, restart: true, stop: true, status: true
    action :nothing
  end

  directory node['glassfish']['domains_dir'] do
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode '0755'
    recursive true
  end

  master_password = new_resource.master_password || new_resource.password

  if master_password.nil? || master_password.length <= 6
    raise 'The master_password parameter is unspecified and defaulting to the domain password. The user must specify a master_password greater than 6 characters or increase the size of the domain password to be greater than 6 characters.' if new_resource.master_password.nil?
    raise 'The master_password parameter must be greater than 6 characters.'
  end

  if new_resource.password_file
    template new_resource.password_file do
      cookbook 'glassfish'
      not_if { new_resource.password.nil? }
      source 'password.erb'
      sensitive true
      owner new_resource.system_user
      group new_resource.system_group unless node.windows?
      mode '0600'
      variables password: new_resource.password, master_password: master_password
    end
  end

  authbind_port "AuthBind GlassFish Port #{new_resource.port}" do
    only_if { new_resource.port < 1024 }
    port new_resource.port
    user new_resource.system_user unless node.windows?
  end

  authbind_port "AuthBind GlassFish Port #{new_resource.admin_port}" do
    only_if { new_resource.admin_port < 1024 }
    port new_resource.admin_port
    user new_resource.system_user unless node.windows?
  end

  cookbook_file "#{new_resource.domain_dir_path}/config/default-web.xml" do
    source "default-web-#{node['glassfish']['version']}.xml"
    cookbook 'glassfish'
    owner node['glassfish']['user']
    group node['glassfish']['group']
    mode '0644'
    action :nothing
  end

  file "#{new_resource.domain_dir_path}/docroot/index.html" do
    action :nothing
  end

  execute "create domain #{new_resource.domain_name}" do
    not_if "#{asadmin_command('list-domains')} #{domain_dir_arg}| grep -- '#{new_resource.domain_name} '", timeout: node['glassfish']['asadmin']['timeout'] + 5

    create_args = []
    create_args << '--checkports=false'
    create_args << '--savemasterpassword=true'
    create_args << "--portbase #{new_resource.portbase}" if new_resource.portbase
    create_args << "--instanceport #{new_resource.port}" unless new_resource.portbase
    create_args << "--adminport #{new_resource.admin_port}" unless new_resource.portbase
    create_args << '--nopassword=false' if new_resource.username
    create_args << "--keytooloptions CN=#{new_resource.certificate_cn}" if new_resource.certificate_cn
    create_args << domain_dir_arg

    # execute should wait for asadmin to time out first, if it doesn't because of some problem, execute should time out eventually
    timeout node['glassfish']['asadmin']['timeout'] + 5
    user new_resource.system_user
    group new_resource.system_group
    command (requires_authbind ? 'authbind --deep ' : '') + asadmin_command("create-domain #{create_args.join(' ')} #{new_resource.domain_name}", false) # rubocop:disable Lint/ParenthesesAsGroupedExpression

    notifies :create, "cookbook_file[#{new_resource.domain_dir_path}/config/default-web.xml]", :immediately if node['glassfish']['variant'] != 'payara'

    notifies :delete, "file[#{new_resource.domain_dir_path}/docroot/index.html]", :immediately
    notifies :start, "service[#{service_name}]", :delayed
  end

  # There is a bug in the Glassfish 4 domain creation that puts the master-password in the wrong spot. This copies it back.
  ruby_block 'copy master-password' do
    source_file = "#{new_resource.domain_dir_path}/config/master-password"
    dest_file = "#{new_resource.domain_dir_path}/master-password"

    only_if { node['glassfish']['version'][0] == '4' }
    only_if { ::File.exist?(source_file) }
    not_if { ::File.exist?(dest_file) }

    block do
      FileUtils.cp(source_file, dest_file)
      FileUtils.chown(new_resource.system_user, new_resource.system_group, dest_file)
    end
  end

  template "#{new_resource.domain_dir_path}/config/logging.properties" do
    source 'logging.properties.erb'
    mode '0600'
    cookbook 'glassfish'
    owner new_resource.system_user
    group new_resource.system_group
    variables(logging_properties: new_resource.default_logging_properties.merge(new_resource.logging_properties))
    notifies :restart, "service[#{service_name}]", :delayed
  end

  template "#{new_resource.domain_dir_path}/config/login.conf" do
    source 'login.conf.erb'
    mode '0600'
    cookbook 'glassfish'
    owner new_resource.system_user
    group new_resource.system_group
    variables(realm_types: new_resource.default_realm_confs.merge(new_resource.realm_types))
    notifies :restart, "service[#{service_name}]", :delayed
  end

  # Directory required for Payara 4.1.151
  directory "#{new_resource.domain_dir_path}/bin" do
    owner new_resource.system_user
    group new_resource.system_group
    mode '0755'
  end

  # Directory required for Payara 4.1.152
  %w(lib lib/ext).each do |dir|
    directory "#{new_resource.domain_dir_path}/#{dir}" do
      owner new_resource.system_user
      group new_resource.system_group
      mode '0755'
    end
  end

  file "#{new_resource.domain_dir_path}/bin/#{new_resource.domain_name}_asadmin" do
    mode '0700'
    owner new_resource.system_user
    group new_resource.system_group
    content <<-SH
#!/bin/sh

#{Asadmin.asadmin_command(node, '"$@"', remote_command: true, terse: false, echo: true, username: new_resource.username, password_file: new_resource.password_file, secure: new_resource.secure, admin_port: new_resource.admin_port)}
    SH
  end

  template "/lib/systemd/system/#{service_name}.service" do
    not_if { new_resource.systemd_enabled }
    case node['platform_family']
    when 'debian'
      source 'init.d.ubuntu.erb'
    when 'rhel'
      source 'init.d.erb'
    end
    mode '0744'
    cookbook 'glassfish'

    asadmin = Asadmin.asadmin_script(node)
    password_file = new_resource.password_file ? "--passwordfile=#{new_resource.password_file}" : ''

    variables(new_resource: new_resource,
              start_domain_command: "#{asadmin} start-domain #{password_file} --verbose false --debug false --upgrade false #{domain_dir_arg} #{new_resource.domain_name}",
              restart_domain_command: "#{asadmin} restart-domain #{password_file} #{domain_dir_arg} #{new_resource.domain_name}",
              stop_domain_command: "#{asadmin} stop-domain #{password_file} #{domain_dir_arg} #{new_resource.domain_name}",
              authbind: requires_authbind)
    notifies :restart, "service[#{service_name}]", :delayed
  end

  template "/lib/systemd/system/#{service_name}.service" do
    only_if { new_resource.systemd_enabled }
    source 'systemd.service.erb'
    mode '0644'
    cookbook 'glassfish'

    asadmin = Asadmin.asadmin_script(node)
    password_file = new_resource.password_file ? "--passwordfile=#{new_resource.password_file}" : ''

    variables(new_resource: new_resource,
              start_domain_command: "#{asadmin} start-domain #{password_file} --verbose false --debug false --upgrade false #{domain_dir_arg} #{new_resource.domain_name}",
              start_domain_timeout: new_resource.systemd_start_timeout,
              restart_domain_command: "#{asadmin} restart-domain #{password_file} #{domain_dir_arg} #{new_resource.domain_name}",
              stop_domain_command: "#{asadmin} stop-domain #{password_file} #{domain_dir_arg} #{new_resource.domain_name}",
              stop_domain_timeout: new_resource.systemd_stop_timeout,
              authbind: requires_authbind)
    notifies :restart, "service[#{service_name}]", :delayed
  end

  service service_name do
    supports start: true, restart: true, stop: true, status: true
    action [:enable]
  end
end

action :destroy do
  service service_name do
    action [:stop, :disable]
    ignore_failure true
  end

  file "/etc/init.d/#{service_name}" do
    action :delete
  end

  file "/lib/systemd/system/#{service_name}.service" do
    action :delete
  end

  directory new_resource.domain_dir_path do
    recursive true
    action :delete
  end
end
