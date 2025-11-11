output "vm_ips" {
  description = "IP addresses of all created VMs"
  value = {
    gateway      = "10.0.10.30, 192.168.50.1"
	gitlab        = "192.168.50.10"
    k3s-master    = "192.168.50.20"
    k3s-worker-1  = "192.168.50.21"
    k3s-worker-2  = "192.168.50.22"  
  }
}

output "vm_ids" {
  description = "VM IDs of all created VMs"
  value = {
    gateway       = 200 
	gitlab        = 201
    k3s-master    = 210
    k3s-worker-1  = 211
    k3s-worker-2  = 212

  }
}

output "ssh_commands" {
  description = "SSH connection commands"
  value = {
	gateway       = "ssh admin@10.0.10.30  # или ssh admin@192.168.50.1"
	gitlab        = "ssh admin@192.168.50.10"
    k3s-master    = "ssh admin@192.168.50.20"
    k3s-worker-1  = "ssh admin@192.168.50.21"
    k3s-worker-2  = "ssh admin@192.168.50.22"
    
  }
}

output "vm_roles" {
  description = "Roles and purposes of all created VMs"
  value = {
    gateway       = "Gateway, DNS server, Management Jump Host, HAProxy"
	gitlab        = "CI Server"
    k3s-master    = "K3s Control Plane"
    k3s-worker-1  = "K3s Worker"
    k3s-worker-2  = "K3s Worker" 
  }
}

output "network_summary" {
  description = "Network configuration summary"
  value = {
    external_network = "10.0.10.0/24 (vmbr0)"
    internal_network = "192.168.50.0/24 (vmbr1)"
    dual_homed_vms   = "gateway"
    internal_only_vms = "k3s-master, k3s-worker-1, k3s-worker-2, gitlab"
  }
}