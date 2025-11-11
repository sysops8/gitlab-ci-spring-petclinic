# Подключение к Proxmox
proxmox_api_url  = "https://10.0.10.200:8006/api2/json"
proxmox_username = "terraform@pam"
proxmox_password = "your_secure_password_here"
proxmox_node     = "pve"

# Хранилища
storage_ssd = "local-ssd-seagate2tb"      # Для дисков виртуальных машин
storage_hdd = "local-hdd-wd2tb"          # Для образов и snippets

# Шаблон
template_vm_id = 9999          # ID шаблона 

# Пользователь и SSH
admin_user          = "admin"
admin_password      = "your_admin_password_here"
ssh_public_key_path = "id_rsa.pub"

# Cloud Image (если нужно)
cloud_image_url = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"