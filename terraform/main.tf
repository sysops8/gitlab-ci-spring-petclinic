terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.83.1"
    }
  }
  required_version = ">= 1.0"
}

provider "proxmox" {
  endpoint = var.proxmox_api_url
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = true
}

# Локальные переменные с конфигурацией всех VM
locals {
  vms = {
    gateway = {
      vm_id           = 200
      cores           = 2
      memory          = 2048
      disk_size       = 20
      extra_disk_size = null
      networks = [
        { bridge = "vmbr0", ip = "10.0.10.30/24", gateway = "10.0.10.1" },
        { bridge = "vmbr1", ip = "192.168.50.1/24", gateway = null }
      ]
    }
	gitlab = {
      vm_id           = 201
      cores           = 2
      memory          = 4096
      disk_size       = 40
      extra_disk_size = null
      networks = [
        { bridge = "vmbr1", ip = "192.168.50.10/24", gateway = "192.168.50.1" }
      ]
    } 

    k3s-master = {
      vm_id           = 220
      cores           = 4
      memory          = 8192
      disk_size       = 60
      extra_disk_size = null
      networks = [
        { bridge = "vmbr1", ip = "192.168.50.20/24", gateway = "192.168.50.1" }
      ]
    }
    k3s-worker-1 = {
      vm_id           = 221
      cores           = 4
      memory          = 10240
      disk_size       = 80
      extra_disk_size = null
      networks = [
        { bridge = "vmbr1", ip = "192.168.50.21/24", gateway = "192.168.50.1" }
      ]
    }
    k3s-worker-2 = {
      vm_id           = 222
      cores           = 4
      memory          = 10240
      disk_size       = 80
      extra_disk_size = null
      networks = [
        { bridge = "vmbr1", ip = "192.168.50.22/24", gateway = "192.168.50.1" }
      ]
    }
  }
}

# Cloud-init файлы для каждой VM (исправленная версия)
resource "proxmox_virtual_environment_file" "vm_cloud_init" {
  for_each = local.vms

  content_type = "snippets"
  datastore_id = var.storage_hdd
  node_name    = var.proxmox_node

  source_raw {
    data = <<-EOF
#cloud-config
hostname: ${each.key}
manage_etc_hosts: true
EOF
    file_name = "cloud-init-${each.key}.yml"
  }
}

# Создание всех VM через for_each
resource "proxmox_virtual_environment_vm" "vms" {
  for_each = local.vms

  name      = each.key
  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "x86-64-v2"
  }

  memory {
    dedicated = each.value.memory
  }

  # Основной диск
  disk {
    datastore_id = var.storage_ssd
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = "raw"
  }

  # Дополнительный диск (для MinIO)
  dynamic "disk" {
    for_each = each.value.extra_disk_size != null ? [1] : []
    content {
      datastore_id = var.storage_ssd
      interface    = "scsi1"
      size         = each.value.extra_disk_size
      file_format  = "raw"
    }
  }

  # Сетевые интерфейсы
  dynamic "network_device" {
    for_each = each.value.networks
    iterator = network
    content {
      bridge = network.value.bridge
      model  = "virtio"
    }
  }

  operating_system {
    type = "l26"
  }

  # Инициализация
  initialization {
    datastore_id = var.storage_hdd
    interface    = "ide2"

    # IP конфигурация для каждого сетевого интерфейса
    dynamic "ip_config" {
      for_each = each.value.networks
      iterator = network
      content {
        ipv4 {
          address = network.value.ip
          gateway = network.value.gateway
        }
      }
    }
    
    # Учетная запись пользователя
    user_account {
      username = var.admin_user
      keys     = [file(var.ssh_public_key_path)]
      password = var.admin_password
    }

    # Используем cloud-init для hostname
    user_data_file_id = proxmox_virtual_environment_file.vm_cloud_init[each.key].id
  }

  # Включаем QEMU agent
  agent {
    enabled = true
    type    = "virtio"
    timeout = "1m"
  }
}

