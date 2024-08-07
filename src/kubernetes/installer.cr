require "crinja"
require "base64"
require "file_utils"

require "../util"
require "../util/ssh"
require "../util/shell"
require "../hetzner/server"
require "../hetzner/load_balancer"
require "../configuration/loader"
require "./software/system_upgrade_controller"
require "./software/hetzner/secret"
require "./software/hetzner/cloud_controller_manager"
require "./software/hetzner/csi_driver"
require "./software/cluster_autoscaler"

class Kubernetes::Installer
  MASTER_INSTALL_SCRIPT = {{ read_file("#{__DIR__}/../../templates/master_install_script.sh") }}
  WORKER_INSTALL_SCRIPT = {{ read_file("#{__DIR__}/../../templates/worker_install_script.sh") }}

  getter configuration : Configuration::Loader
  getter settings : Configuration::Main { configuration.settings }
  getter masters : Array(Hetzner::Server)
  getter workers : Array(Hetzner::Server)
  getter autoscaling_worker_node_pools : Array(Configuration::NodePool)
  getter load_balancer : Hetzner::LoadBalancer?
  getter ssh : Util::SSH

  getter first_master : Hetzner::Server { masters[0] }
  getter api_server_ip_address : String { masters.size > 1 ? load_balancer.not_nil!.public_ip_address.not_nil! : first_master.host_ip_address.not_nil! }
  getter tls_sans : String { generate_tls_sans }

  def initialize(@configuration, @masters, @workers, @load_balancer, @ssh, @autoscaling_worker_node_pools)
  end

  def run
    Util.check_kubectl

    puts "\n=== Setting up Kubernetes ===\n"

    set_up_first_master
    set_up_other_masters
    set_up_workers


    add_labels_and_taints_to_masters
    add_labels_and_taints_to_workers

    install_software
  end

  private def set_up_first_master
    puts "Deploying k3s to first master #{first_master.name}..."

    output = ssh.run(first_master, settings.ssh_port, master_install_script(first_master), settings.use_ssh_agent)

    puts "Waiting for the control plane to be ready..."

    sleep 10 unless /No change detected/ =~ output

    save_kubeconfig

    puts "...k3s has been deployed to first master #{first_master.name} and the control plane is up."
  end

  private def set_up_other_masters
    channel = Channel(Hetzner::Server).new
    other_masters = masters[1..-1]

    deploy_masters_in_parallel(channel, other_masters)
    wait_for_masters_deployment(channel, other_masters.size)
  end

  private def deploy_masters_in_parallel(channel : Channel(Hetzner::Server), other_masters : Array(Hetzner::Server))
    other_masters.each do |master|
      spawn do
        deploy_k3s_to_master(master)
        channel.send(master)
      end
    end
  end

  private def deploy_k3s_to_master(master : Hetzner::Server)
    puts "Deploying k3s to master #{master.name}..."
    ssh.run(master, settings.ssh_port, master_install_script(master), settings.use_ssh_agent)
    puts "...k3s has been deployed to master #{master.name}."
  end

  private def wait_for_masters_deployment(channel : Channel(Hetzner::Server), num_masters : Int32)
    num_masters.times { channel.receive }
  end

  private def set_up_workers
    channel = Channel(Hetzner::Server).new

    deploy_workers_in_parallel(channel, workers)
    wait_for_workers_deployment(channel, workers.size)
  end

  private def deploy_workers_in_parallel(channel : Channel(Hetzner::Server), workers : Array(Hetzner::Server))
    workers.each do |worker|
      spawn do
        deploy_k3s_to_worker(worker)
        channel.send(worker)
      end
    end
  end

  private def deploy_k3s_to_worker(worker : Hetzner::Server)
    puts "Deploying k3s to worker #{worker.name}..."
    ssh.run(worker, settings.ssh_port, worker_install_script, settings.use_ssh_agent)
    puts "...k3s has been deployed to worker #{worker.name}."
  end

  private def wait_for_workers_deployment(channel : Channel(Hetzner::Server), num_workers : Int32)
    num_workers.times { channel.receive }
  end

  private def master_install_script(master)
    server = ""
    datastore_endpoint = ""
    etcd_arguments = ""

    if settings.datastore.mode == "etcd"
      server = master == first_master ? " --cluster-init " : " --server https://#{api_server_ip_address}:6443 "
      etcd_arguments = " --etcd-expose-metrics=true "
    else
      datastore_endpoint = " K3S_DATASTORE_ENDPOINT='#{settings.datastore.external_datastore_endpoint}' "
    end

    flannel_backend = find_flannel_backend
    extra_args = "#{kube_api_server_args_list} #{kube_scheduler_args_list} #{kube_controller_manager_args_list} #{kube_cloud_controller_manager_args_list} #{kubelet_args_list} #{kube_proxy_args_list}"
    taint = settings.schedule_workloads_on_masters ? " " : " --node-taint CriticalAddonsOnly=true:NoExecute "

    Crinja.render(MASTER_INSTALL_SCRIPT, {
      cluster_name: settings.cluster_name,
      k3s_version: settings.k3s_version,
      k3s_token: k3s_token,
      disable_flannel: settings.disable_flannel.to_s,
      flannel_backend: flannel_backend,
      taint: taint,
      extra_args: extra_args,
      server: server,
      tls_sans: tls_sans,
      private_network_test_ip: settings.private_network_subnet.split(".")[0..2].join(".") + ".0",
      cluster_cidr: settings.cluster_cidr,
      service_cidr: settings.service_cidr,
      cluster_dns: settings.cluster_dns,
      datastore_endpoint: datastore_endpoint,
      etcd_arguments: etcd_arguments
    })
  end

  private def worker_install_script
    Crinja.render(WORKER_INSTALL_SCRIPT, {
      cluster_name: settings.cluster_name,
      k3s_token: k3s_token,
      k3s_version: settings.k3s_version,
      first_master_private_ip_address: first_master.private_ip_address,
      private_network_test_ip: settings.private_network_subnet.split(".")[0..2].join(".") + ".0"
    })
  end

  private def find_flannel_backend
    return " " unless configuration.settings.enable_encryption

    available_releases = K3s.available_releases
    selected_k3s_index = available_releases.index(settings.k3s_version).not_nil!
    k3s_1_23_6_index = available_releases.index("v1.23.6+k3s1").not_nil!

    selected_k3s_index >= k3s_1_23_6_index ? " --flannel-backend=wireguard-native " : " --flannel-backend=wireguard "
  end

  private def args_list(settings_group, setting)
    setting.map { |arg| " --#{settings_group}-arg=\"#{arg}\" " }.join
  end

  private def kube_api_server_args_list
    args_list("kube-apiserver", settings.kube_api_server_args)
  end

  private def kube_scheduler_args_list
    args_list("kube-scheduler", settings.kube_scheduler_args)
  end

  private def kube_controller_manager_args_list
    args_list("kube-controller-manager", settings.kube_controller_manager_args)
  end

  private def kube_cloud_controller_manager_args_list
    args_list("kube-cloud-controller-manager", settings.kube_cloud_controller_manager_args)
  end

  private def kubelet_args_list
    args_list("kubelet", settings.kubelet_args)
  end

  private def kube_proxy_args_list
    args_list("kube-proxy", settings.kube_proxy_args)
  end

  private def k3s_token
    token = begin
      ssh.run(first_master, settings.ssh_port, "cat /var/lib/rancher/k3s/server/node-token", settings.use_ssh_agent, print_output: false)
    rescue
      ""
    end

    token.empty? ? Random::Secure.hex : token.split(':').last
  end

  private def save_kubeconfig
    kubeconfig_path = configuration.kubeconfig_path

    puts "Saving the kubeconfig file to #{kubeconfig_path}..."

    kubeconfig = ssh.run(first_master, settings.ssh_port, "cat /etc/rancher/k3s/k3s.yaml", settings.use_ssh_agent, print_output: false).
      gsub("127.0.0.1",  api_server_ip_address).
      gsub("default", settings.cluster_name)

    File.write(kubeconfig_path, kubeconfig)

    File.chmod kubeconfig_path, 0o600
  end



  private def add_labels_and_taints_to_masters
    add_labels_or_taints(:label, masters, settings.masters_pool.labels, :master)
    add_labels_or_taints(:taint, masters, settings.masters_pool.taints, :master)
  end

  private def add_labels_and_taints_to_workers
    settings.worker_node_pools.each do |node_pool|
      instance_type = node_pool.instance_type
      node_name_prefix = /#{settings.cluster_name}-#{instance_type}-pool-#{node_pool.name}-worker/

      nodes = workers.select { |worker| node_name_prefix =~ worker.name }

      add_labels_or_taints(:label, nodes, node_pool.labels, :worker)
      add_labels_or_taints(:taint, nodes, node_pool.taints, :worker)
    end
  end

  private def add_labels_or_taints(mark_type, servers, marks, server_type)
    return unless marks.any?

    node_names = servers.map(&.name).join(" ")

    puts "\nAdding #{mark_type}s to #{server_type}s..."

    all_marks = marks.map do |mark|
      "#{mark.key}=#{mark.value}"
    end.join(" ")

    command = "kubectl #{mark_type} --overwrite nodes #{node_names} #{all_marks}"

    Util::Shell.run(command, configuration.kubeconfig_path, settings.hetzner_token)

    puts "...done."
  end

  private def generate_tls_sans
    sans = ["--tls-san=#{api_server_ip_address}"]
    sans << "--tls-san=#{settings.api_server_hostname}" if settings.api_server_hostname
    sans << "--tls-san=#{load_balancer.not_nil!.private_ip_address}" if masters.size > 1

    masters.each do |master|
      master_private_ip = master.private_ip_address
      sans << "--tls-san=#{master_private_ip}"
    end
    sans.join(" ")
  end

  private def install_software
    Kubernetes::Software::Hetzner::Secret.new(configuration, settings).create
    Kubernetes::Software::Hetzner::CloudControllerManager.new(configuration, settings).install
    Kubernetes::Software::Hetzner::CSIDriver.new(configuration, settings).install
    Kubernetes::Software::SystemUpgradeController.new(configuration, settings).install
    Kubernetes::Software::ClusterAutoscaler.new(configuration, settings, first_master, ssh, autoscaling_worker_node_pools, worker_install_script).install
  end
end
