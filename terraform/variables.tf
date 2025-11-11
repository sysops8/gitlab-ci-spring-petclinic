variable "proxmox_api_url" {
  description = "URL API Proxmox"
  type        = string
}

variable "proxmox_username" {
  description = "Имя пользователя Proxmox (например: terraform@pam)"
  type        = string
}

variable "proxmox_password" {
  description = "Пароль пользователя Proxmox"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Имя узла Proxmox"
  type        = string
}

variable "storage_ssd" {
  description = "ID хранилища SSD для дисков VM"
  type        = string
  default     = "local-ssd-seagate2tb"
}

variable "storage_hdd" {
  description = "ID хранилища для образов и snippets"
  type        = string
  default     = "local-hdd-wd2tb"
}

variable "template_vm_id" {
  description = "ID шаблона VM"
  type        = number
  default     = 9999
}

variable "admin_user" {
  description = "Пользователь администратор"
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Пароль администратора (будет установлен и для root)"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Путь к публичному SSH ключу"
  type        = string
  default     = "id_rsa.pub"
}

variable "cloud_image_url" {
  description = "URL cloud image для загрузки"
  type        = string
  default     = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
}

# Опциональные переменные (если нужны для SSH cleanup)
variable "proxmox_ssh_host" {
  description = "Proxmox host IP (для cleanup)"
  type        = string
  default     = ""
}

variable "proxmox_ssh_username" {
  description = "Имя пользователя ssh Proxmox (для cleanup)"
  type        = string
  default     = ""
}