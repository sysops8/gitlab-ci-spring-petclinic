# Spring PetClinic CI/CD Pipeline на Proxmox

Исчерпывающее руководство по развертыванию production-ready CI/CD pipeline с GitLab, Kubernetes, Maven, Nexus, SonarQube на домашнем Proxmox сервере с полной сетевой изоляцией.

## Оглавление

1. [Архитектура решения](#архитектура-решения)
2. [Подготовка виртуальных машин](#часть-1-подготовка-виртуальных-машин)
3. [Настройка сетевого шлюза](#часть-2-настройка-сетевого-шлюза)
4. [Установка GitLab CE](#часть-3-установка-gitlab-ce)
5. [Установка K3s Kubernetes](#часть-4-установка-k3s-kubernetes)
6. [Установка Helm](#часть-5-установка-helm)
7. [Установка SonarQube](#часть-6-установка-sonarqube)
8. [Установка Nexus Repository](#часть-7-установка-nexus-repository)
9. [Настройка HAProxy](#часть-8-настройка-haproxy)
10. [Настройка Nexus](#часть-9-настройка-nexus-repository)
11. [Настройка SonarQube](#часть-10-настройка-sonarqube)
12. [Настройка GitLab CI/CD](#часть-11-настройка-gitlab-cicd)
13. [Установка GitLab Runner](#часть-12-установка-gitlab-runner)
14. [Запуск Pipeline](#часть-13-запуск-и-тестирование-pipeline)
15. [Мониторинг и отладка](#часть-14-мониторинг-и-отладка)
16. [Дополнительные настройки](#часть-15-дополнительные-настройки)

---

![Архитектура проекта](https://github.com/user-attachments/assets/2147bb46-47ae-4e0e-80af-279fdf1183cf)

## Архитектура решения

### Компоненты инфраструктуры

| Компонент | Назначение | Версия |
|-----------|-----------|---------|
| **GitLab CE** | Система управления репозиториями и CI/CD оркестрация | Latest |
| **Kubernetes (K3s)** | Легковесная оркестрация контейнеров | v1.27+ |
| **Nexus Repository** | Хранилище артефактов (Maven, Docker) | 3.x |
| **SonarQube** | Статический анализ качества кода | 9.9+ LTS |
| **GitLab Runner** | Исполнитель CI/CD задач в Kubernetes | Latest |
| **HAProxy** | Реверс-прокси и балансировщик нагрузки | 2.8+ |
| **BIND9** | Авторитативный DNS сервер для внутренней зоны | 9.18+ |
| **MetalLB** | Bare-metal LoadBalancer для Kubernetes | v0.13+ |

### Сетевая архитектура

#### Внешняя сеть: 10.0.10.0/24
- Интернет (серый IP) → Router (10.0.10.1)
- Proxmox Host: 10.0.10.200
- Gateway (внешний интерфейс): 10.0.10.30

#### Внутренняя сеть: 192.168.50.0/24 (изолированная DMZ)
- Gateway (внутренний интерфейс): 192.168.50.1
  - Роли: NAT gateway, DNS сервер, Jump host, HAProxy
- GitLab VM: 192.168.50.10
- K3s Master: 192.168.50.20
- K3s Worker-1: 192.168.50.21
- K3s Worker-2: 192.168.50.22
- SonarQube: 192.168.50.30
- Nexus Repository: 192.168.50.31
- MetalLB IP Pool: 192.168.50.100-192.168.50.150

#### Сервисы Kubernetes (MetalLB)
- PetClinic: 192.168.50.103:80

### Преимущества архитектуры

✅ **Безопасность**: Полная изоляция DevOps инфраструктуры во внутренней сети  
✅ **Единая точка доступа**: Все сервисы через HAProxy на шлюзе  
✅ **DNS резолвинг**: Локальная зона .local.lab без редактирования hosts  
✅ **Масштабируемость**: Легко добавлять новые ноды и сервисы  
✅ **Отказоустойчивость**: Несколько worker нод для Kubernetes  

### Диаграмма сетевой топологии

```
Internet (Grey IP)
       │
       ├→ Router (10.0.10.1)
       │
       └→ Proxmox Host (10.0.10.200)
                │
                ├→ vmbr0 (Внешняя сеть: 10.0.10.0/24)
                │        │
                │        └→ Gateway VM (10.0.10.30) ← Доступ извне
                │                 │
                │                 │ (NAT, DNS, HAProxy, Jump)
                │                 │
                └→ vmbr1 (Внутренняя сеть: 192.168.50.0/24)
                          │
                          ├→ Gateway VM (192.168.50.1)
                          ├→ GitLab (192.168.50.10)
                          ├→ K3s Master (192.168.50.20)
                          ├→ K3s Worker-1 (192.168.50.21)
                          ├→ K3s Worker-2 (192.168.50.22)
                          ├→ SonarQube (192.168.50.30)
                          ├→ Nexus (192.168.50.31)
                          └→ MetalLB Services (192.168.50.100+)
```

---

## Часть 1: Подготовка виртуальных машин

### 1.1 Требования к ресурсам VM

| VM | CPU | RAM | Disk | Назначение | IP адрес внут./внеш. |
|----|-----|-----|------|-----------|-----------|
| Gateway | 2 | 4GB | 20GB | NAT, DNS (BIND), HAProxy, Jump host | 192.168.50.1 / 10.0.10.30 |
| GitLab | 4 | 8GB | 50GB | Git repository, CI/CD orchestration | 192.168.50.10 |
| K3s Master | 2 | 4GB | 40GB | Kubernetes control plane | 192.168.50.20 |
| K3s Worker-1 | 2 | 8GB | 60GB | Kubernetes workloads | 192.168.50.21 |
| K3s Worker-2 | 2 | 8GB | 60GB | Kubernetes workloads | 192.168.50.22 |
| SonarQube | 2 | 4GB | 40GB | Code Scanning | 192.168.50.30 |
| Nexus | 2 | 4GB | 100GB | Nexus repository | 192.168.50.31 |

**Итого**: 14 vCPU, 40GB RAM, 370GB Disk

### 1.2 Настройка сетевых bridge на Proxmox

SSH на Proxmox хост:

```bash
ssh root@10.0.10.200
```

Проверьте текущую конфигурацию:

```bash
cat /etc/network/interfaces
```

Добавьте внутренний bridge (если отсутствует):

```bash
nano /etc/network/interfaces
```

Добавьте в конец файла:

```
# Внутренняя изолированная сеть
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094
# Internal DevOps network
```

Применение изменений:

```bash
ifreload -a
# или при проблемах:
systemctl restart networking
```

Проверка:

```bash
ip link show vmbr1
brctl show vmbr1
```

**Важно**: vmbr1 не имеет IP адреса на Proxmox хосте - это только L2 bridge.

### 1.3 Создание Cloud-Init шаблона Ubuntu 22.04

В папке Terraform будет автоматическая установка шаблона Ubuntu 22.04

### 1.4 Terraform конфигурация для Proxmox

В папке Terraform все файлы по созданию VM и шаблона для этого проекта

---

## Часть 2: Настройка сетевого шлюза

Gateway выполняет четыре критические функции:
1. **NAT Gateway** - обеспечивает доступ внутренней сети в интернет
2. **DNS Server (BIND9)** - резолвинг локальной зоны .local.lab
3. **Jump Host** - единая точка SSH доступа к внутренней сети
4. **Reverse Proxy (HAProxy)** - проксирование HTTP трафика к сервисам

### 2.1 Подключение к Gateway

```bash
ssh ubuntu@10.0.10.30
```

### 2.2 Базовая настройка системы

```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка базовых утилит
sudo apt install -y \
  vim \
  curl \
  wget \
  net-tools \
  htop \
  iptables-persistent \
  dnsutils \
  tcpdump

# Проверка сетевых интерфейсов
ip addr show
```

Ожидаемый вывод:

```
eth0: 10.0.10.30/24 (внешний)
eth1: 192.168.50.1/24 (внутренний)
```

**Важно**: Имена интерфейсов могут отличаться (eth0, enp0s18, ens18 и т.д.). Используйте актуальные имена в дальнейших командах.

### 2.3 Настройка IP Forwarding и NAT

```bash
# Включение IP forwarding перманентно
sudo tee -a /etc/sysctl.conf > /dev/null <<EOF

# Enable IP forwarding for NAT gateway
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
EOF

# Применение изменений
sudo sysctl -p

# Проверка
sysctl net.ipv4.ip_forward
```

Настройка iptables для NAT:

```bash
# Определение интерфейсов
EXT_IF="eth0"  # Внешний интерфейс - замените на свой!
INT_IF="eth1"  # Внутренний интерфейс - замените на свой!

# Очистка существующих правил (опционально)
sudo iptables -F
sudo iptables -t nat -F

# Настройка NAT (MASQUERADE)
sudo iptables -t nat -A POSTROUTING -o $EXT_IF -j MASQUERADE

# Разрешение forwarding для внутренней сети
sudo iptables -A FORWARD -i $INT_IF -o $EXT_IF -j ACCEPT
sudo iptables -A FORWARD -i $EXT_IF -o $INT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT

# Разрешение loopback
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A OUTPUT -o lo -j ACCEPT

# Разрешение SSH на внешнем интерфейсе
sudo iptables -A INPUT -i $EXT_IF -p tcp --dport 22 -j ACCEPT

# Разрешение HTTP/HTTPS на внешнем интерфейсе (для HAProxy)
sudo iptables -A INPUT -i $EXT_IF -p tcp --dport 80 -j ACCEPT
sudo iptables -A INPUT -i $EXT_IF -p tcp --dport 443 -j ACCEPT

# Разрешение DNS на внутреннем интерфейсе
sudo iptables -A INPUT -i $INT_IF -p udp --dport 53 -j ACCEPT
sudo iptables -A INPUT -i $INT_IF -p tcp --dport 53 -j ACCEPT

# Разрешение established connections
sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT

# Политика по умолчанию
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# Сохранение правил
sudo netfilter-persistent save
```

Проверка правил:

```bash
sudo iptables -L -v -n
sudo iptables -t nat -L -v -n
```

### 2.4 Установка и настройка BIND9 DNS

BIND9 будет авторитативным DNS сервером для зоны `local.lab` и форвардить внешние запросы.

#### 2.4.1 Установка BIND9

```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка BIND9
sudo apt install -y bind9 bind9utils bind9-doc dnsutils

# Остановка systemd-resolved (конфликтует с BIND)
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf
```

#### 2.4.2 Настройка основной конфигурации

Редактирование главного конфигурационного файла:

```bash
sudo bash -c 'cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    // Слушать на всех интерфейсах
    listen-on { 127.0.0.1; 192.168.50.1; };
    listen-on-v6 { none; };

    // Разрешить запросы из локальных сетей
    allow-query { 
        localhost; 
        192.168.50.0/24;        
    };

    // Рекурсия для локальных сетей
    recursion yes;
    allow-recursion { 
        localhost; 
        192.168.50.0/24;    
    };

    // Форвардинг на публичные DNS
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };

    dnssec-validation auto;
    auth-nxdomain no;
};
EOF'
```

#### 2.4.3 Создание зоны local.lab

Редактирование локальных зон:

```bash
sudo bash -c 'cat > /etc/bind/named.conf.local <<EOF
// Прямая зона для local.lab
zone "local.lab" {
    type master;
    file "/etc/bind/zones/db.local.lab";
    allow-update { none; };
};

// Обратная зона для 192.168.50.0/24
zone "50.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/zones/db.192.168.50";
    allow-update { none; };
};
EOF'
```

#### 2.4.4 Создание файлов зон

Создайте директорию для зон:

```bash
sudo mkdir -p /etc/bind/zones
```

Создайте прямую зону:

```bash
sudo bash -c 'cat > /etc/bind/zones/db.local.lab <<EOF
\$TTL    604800
@       IN      SOA     ns1.local.lab. admin.local.lab. (
                              3         ; Serial (увеличивайте при изменениях)
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

; Name servers
@       IN      NS      ns1.local.lab.

; A records для name server
ns1     IN      A       192.168.50.1

; A records для инфраструктуры
gateway         IN      A       192.168.50.1
gitlab          IN      A       192.168.50.10
k3s-master      IN      A       192.168.50.20
k3s-worker-1    IN      A       192.168.50.21
k3s-worker-2    IN      A       192.168.50.22
sonarqube       IN      A       192.168.50.30
nexus           IN      A       192.168.50.31

; A records для сервисов (MetalLB IPs)
petclinic       IN      A       192.168.50.103

; CNAME aliases (опционально)
git             IN      CNAME   gitlab
sonar           IN      CNAME   sonarqube
repo            IN      CNAME   nexus
app             IN      CNAME   petclinic
EOF'
```

Создайте обратную зону:

```bash
sudo bash -c 'cat > /etc/bind/zones/db.192.168.50 <<EOF
\$TTL    604800
@       IN      SOA     ns1.local.lab. admin.local.lab. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

; Name server
@       IN      NS      ns1.local.lab.

; PTR records
1       IN      PTR     gateway.local.lab.
1       IN      PTR     ns1.local.lab.
10      IN      PTR     gitlab.local.lab.
20      IN      PTR     k3s-master.local.lab.
21      IN      PTR     k3s-worker-1.local.lab.
22      IN      PTR     k3s-worker-2.local.lab.
30      IN      PTR     sonarqube.local.lab.
31      IN      PTR     nexus.local.lab.
103     IN      PTR     petclinic.local.lab.
EOF'
```

#### 2.4.5 Проверка конфигурации BIND

```bash
# Проверка синтаксиса основной конфигурации
sudo named-checkconf

# Проверка прямой зоны
sudo named-checkzone local.lab /etc/bind/zones/db.local.lab

# Проверка обратной зоны
sudo named-checkzone 50.168.192.in-addr.arpa /etc/bind/zones/db.192.168.50
```

Ожидаемый вывод (без ошибок):

```
zone local.lab/IN: loaded serial 3
OK
zone 50.168.192.in-addr.arpa/IN: loaded serial 3
OK
```

#### 2.4.6 Запуск и проверка BIND9

```bash
# Перезапуск BIND9
sudo systemctl restart bind9

# Автозапуск
sudo systemctl enable bind9

# Проверка статуса
sudo systemctl status bind9

# Проверка логов
sudo journalctl -u bind9 -f
```

#### 2.4.7 Тестирование DNS

На Gateway:

```bash
# Тест прямого резолвинга
dig @127.0.0.1 gitlab.local.lab
dig @127.0.0.1 nexus.local.lab
nslookup gitlab.local.lab 127.0.0.1

# Тест обратного резолвинга
dig @127.0.0.1 -x 192.168.50.10
nslookup 192.168.50.10 127.0.0.1

# Тест форвардинга внешних запросов
dig @127.0.0.1 google.com
nslookup google.com 127.0.0.1
```

**Важно**: Убедитесь, что все DNS запросы возвращают корректные IP адреса.

#### 2.4.8 Настройка DNS на клиентских машинах

### Настройка DNS на всех VM

#### Ручная настройка Gateway

```bash
ssh ubuntu@10.0.10.30
```

```bash
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf

sudo bash -c 'cat > /etc/resolv.conf <<EOF
nameserver 192.168.50.1
nameserver 8.8.8.8
search local.lab
EOF'

sudo chattr +i /etc/resolv.conf

# Netplan для Gateway (2 интерфейса)
sudo bash -c 'cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses: [10.0.10.30/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.0.10.1
      nameservers:
        addresses: [192.168.50.1, 8.8.8.8]
        search: [local.lab]
    eth1:
      dhcp4: no
      addresses: [192.168.50.1/24]
      nameservers:
        addresses: [192.168.50.1]
        search: [local.lab]
EOF'

sudo apt install -y openvswitch-switch
sudo chmod 600 /etc/netplan/00-installer-config.yaml
sudo netplan apply

# Проверка
ping -c 2 google.com
nslookup k3s-master.local.lab
```

Создайте скрипт для автоматизации:

```bash
# На Gateway создайте файл set-dns.sh
cat > /tmp/set-dns.sh <<'EOF'
#!/bin/bash

echo "Настройка DNS и маршрутизации..."

# Получение текущего IP
CURRENT_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Определение gateway
if [[ $CURRENT_IP == 192.168.50.* ]]; then
    GATEWAY="192.168.50.1"
    NETMASK="24"
elif [[ $CURRENT_IP == 10.0.10.* ]]; then
    GATEWAY="10.0.10.1"
    NETMASK="24"
else
    echo "Неизвестная сеть!"
    exit 1
fi

# Остановка systemd-resolved
sudo systemctl disable systemd-resolved 2>/dev/null
sudo systemctl stop systemd-resolved 2>/dev/null
sudo rm -f /etc/resolv.conf

# Создание resolv.conf
sudo bash -c 'cat > /etc/resolv.conf <<EOL
nameserver 192.168.50.1
nameserver 8.8.8.8
search local.lab
EOL'

sudo chattr +i /etc/resolv.conf

# Обновление netplan
if [ -f /etc/netplan/00-installer-config.yaml ]; then
    sudo bash -c "cat > /etc/netplan/00-installer-config.yaml <<EOL
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses: [${CURRENT_IP}/${NETMASK}]
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY}
      nameservers:
        addresses: [192.168.50.1, 8.8.8.8]
        search: [local.lab]
EOL"
    sudo netplan apply
fi

echo "Настройка завершена!"
echo "Gateway: $GATEWAY"
echo "DNS: 192.168.50.1"

# Тестирование
echo ""
echo "Тестирование DNS..."
nslookup k3s-master.local.lab

echo ""
echo "Тестирование интернета..."
ping -c 2 8.8.8.8
ping -c 2 google.com
EOF

chmod +x /tmp/set-dns.sh
```

#### Применение на всех VM

```bash
# На Gateway создайте список хостов (только внутренние VM)
cat > /tmp/internal-hosts.txt <<EOF
k3s-master.local.lab
k3s-worker-1.local.lab
k3s-worker-2.local.lab
gitlab.local.lab
sonarqube.local.lab
nexus.local.lab
EOF

# Применение скрипта на всех VM
for host in $(cat /tmp/internal-hosts.txt); do
    echo "===================================="
    echo "Настройка $host..."
    scp /tmp/set-dns.sh ubuntu@${host}:/tmp/
    ssh ubuntu@${host} "sudo bash /tmp/set-dns.sh"
    echo ""
done
```

### Проверка доступности интернета

На любой VM в сети 192.168.50.0/24:

```bash
# Проверка маршрутов
ip route show
# Должно быть: default via 192.168.50.1 dev eth0

# Проверка DNS
nslookup google.com

# Проверка интернета
ping -c 4 8.8.8.8
ping -c 4 google.com

# Установка пакетов
sudo apt update
sudo apt install -y curl wget vim
```

### 2.5 Проверка работы Gateway

```bash
# На Gateway проверка связности
ping -c 3 8.8.8.8
ping -c 3 google.com

# На GitLab VM
ping -c 3 8.8.8.8  # должен работать через NAT
ping -c 3 google.com  # должен резолвиться через BIND
nslookup gitlab.local.lab  # должен вернуть 192.168.50.10
```

Соединение на внешней машине из 10.0.10.0/24 с внутренними 192.168.50.0/24:

```bash
# С внутренних VM (через jump)
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10
```

---

## Часть 3: Установка GitLab CE

### 3.1 Подключение к GitLab VM

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10
```

### 3.2 Подготовка системы

```bash
# Обновление
sudo apt update && sudo apt upgrade -y

# Установка зависимостей
sudo apt install -y \
  curl \
  openssh-server \
  ca-certificates \
  tzdata \
  perl \
  postfix

# При установке Postfix выберите "Internet Site"
# Mail name: gitlab.local.lab
```

### 3.3 Установка GitLab CE

```bash
# Добавление репозитория GitLab
curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash

# Установка GitLab с external_url
sudo EXTERNAL_URL="http://gitlab.local.lab" apt install -y gitlab-ce

# Процесс займет 5-10 минут
```

### 3.4 Получение начального пароля root

```bash
# Пароль сгенерирован автоматически
sudo cat /etc/gitlab/initial_root_password

# Сохраните пароль! Файл удаляется через 24 часа
```

### 3.5 Настройка GitLab

```bash
sudo vim /etc/gitlab/gitlab.rb
```

Найдите и измените следующие параметры:

```ruby
# URL доступа
external_url 'http://gitlab.local.lab'

# SSH порт (по умолчанию 22)
gitlab_rails['gitlab_shell_ssh_port'] = 22

# Часовой пояс
gitlab_rails['time_zone'] = 'Asia/Almaty'

# Оптимизация для 8GB RAM
puma['worker_processes'] = 2
puma['min_threads'] = 1
puma['max_threads'] = 4

sidekiq['max_concurrency'] = 10

# Отключение встроенного мониторинга (экономия RAM)
prometheus_monitoring['enable'] = false
grafana['enable'] = false

# Лимиты Gitaly
gitaly['ruby_max_rss'] = 300000000
gitaly['concurrency'] = [
  {
    'rpc' => "/gitaly.SmartHTTPService/PostReceivePack",
    'max_per_repo' => 3
  }, {
    'rpc' => "/gitaly.SSHService/SSHUploadPack",
    'max_per_repo' => 3
  }
]

# Настройка PostgreSQL
postgresql['shared_buffers'] = "256MB"
postgresql['max_worker_processes'] = 4

# Backup настройки (опционально)
gitlab_rails['backup_keep_time'] = 604800  # 7 дней
```

Применение конфигурации:

```bash
# Reconfigure (займет 3-5 минут)
sudo gitlab-ctl reconfigure

# Проверка статуса всех компонентов
sudo gitlab-ctl status

# Проверка логов
sudo gitlab-ctl tail
```

### 3.6 Первоначальная настройка через Web

С вашей рабочей машины откройте браузер:

```
http://gitlab.local.lab
```

1. **Первый вход**:
   - Username: `root`
   - Password: (из файла initial_root_password)

2. **Смените пароль root**:
   - Avatar (верхний правый угол) → Edit profile → Password
   - Установите новый надежный пароль

3. **Отключите регистрацию** (опционально):
   - Admin Area → Settings → General → Sign-up restrictions
   - Снимите "Sign-up enabled"

4. **Настройте видимость проектов**:
   - Admin Area → Settings → General → Visibility and access controls
   - Default project visibility: Internal или Private

### 3.7 Создание тестового проекта

1. New Project → Create blank project
2. Project name: `spring-petclinic`
3. Visibility Level: Public (для тестирования)
4. Initialize with README: снять галочку
5. Create project

**Важно**: Сохраните URL проекта, например: `http://gitlab.local.lab/root/spring-petclinic.git`

---

## Часть 4: Установка K3s Kubernetes

K3s - это легковесный Kubernetes дистрибутив, идеальный для edge и домашних лабораторий.

### 4.1 Установка K3s Master

Подключение к Master:

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20
```

Установка K3s:

```bash
# Установка K3s master с отключением Traefik и ServiceLB
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --node-ip 192.168.50.20 \
  --node-external-ip 192.168.50.20 \
  --flannel-iface eth0 \
  --write-kubeconfig-mode 644

# Проверка установки
sudo systemctl status k3s

# Проверка версии
kubectl version --short

# Проверка node
kubectl get nodes

# Ожидаемый вывод:
# NAME         STATUS   ROLES                  AGE   VERSION
# k3s-master   Ready    control-plane,master   1m    v1.27.x+k3s1
```

### 4.2 Получение токена для Worker nodes

```bash
# Токен для присоединения worker nodes
sudo cat /var/lib/rancher/k3s/server/node-token

# Сохраните токен! Пример:
# K10abc123def456ghi789jkl012mno345pqr::server:678stu901vwx234yz
```

### 4.3 Настройка kubectl для пользователя ubuntu

```bash
# Создание .kube директории
mkdir -p ~/.kube

# Копирование kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown ubuntu:ubuntu ~/.kube/config

# Проверка доступа
kubectl get nodes
kubectl get pods --all-namespaces
```

### 4.4 Установка K3s Worker-1

Подключение:

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.21
```

Установка:

```bash
# Замените K3S_TOKEN на реальный токен с master
export K3S_TOKEN="YOUR_TOKEN_FROM_MASTER"
export K3S_URL="https://192.168.50.20:6443"

curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - \
  --node-ip 192.168.50.21 \
  --flannel-iface eth0

# Проверка статуса
sudo systemctl status k3s-agent
```

### 4.5 Установка K3s Worker-2

Подключение:

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.22
```

Установка:

```bash
# Используйте тот же токен
export K3S_TOKEN="YOUR_TOKEN_FROM_MASTER"
export K3S_URL="https://192.168.50.20:6443"

curl -sfL https://get.k3s.io | K3S_URL=$K3S_URL K3S_TOKEN=$K3S_TOKEN sh -s - \
  --node-ip 192.168.50.22 \
  --flannel-iface eth0

# Проверка
sudo systemctl status k3s-agent
```

### 4.6 Проверка кластера

На Master:

```bash
kubectl get nodes -o wide

# Ожидаемый вывод:
# NAME          STATUS   ROLES                  AGE     VERSION        INTERNAL-IP     
# k3s-master    Ready    control-plane,master   10m     v1.27.x+k3s1   192.168.50.20
# k3s-worker-1  Ready    <none>                 5m      v1.27.x+k3s1   192.168.50.21
# k3s-worker-2  Ready    <none>                 2m      v1.27.x+k3s1   192.168.50.22

# Проверка pods
kubectl get pods --all-namespaces

# Проверка компонентов
kubectl get componentstatuses
```

### 4.7 Установка MetalLB LoadBalancer

MetalLB обеспечивает LoadBalancer IP адреса для Services в bare-metal кластерах.

```bash
# Установка MetalLB через манифесты
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Ожидание готовности
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

# Проверка
kubectl get pods -n metallb-system
```

Создание конфигурации IP Pool:

```bash
cat > metallb-config.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.50.100-192.168.50.150
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF

# Применение
kubectl apply -f metallb-config.yaml

# Проверка
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system
```

**Важно**: MetalLB будет автоматически назначать IP из пула 192.168.50.100-150 для Services типа LoadBalancer.

---

## Часть 5: Установка Helm

Helm - пакетный менеджер для Kubernetes, упрощает развертывание приложений.

### 5.1 Установка Helm на K3s Master

```bash
# Подключение к Master
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20

# Установка Helm через официальный скрипт
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Проверка версии
helm version

# Ожидаемый вывод:
# version.BuildInfo{Version:"v3.13.x", ...}

# Добавление популярных репозиториев
helm repo add stable https://charts.helm.sh/stable
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Проверка
helm repo list
```

---

## Часть 6: Установка SonarQube

SonarQube - платформа для непрерывной инспекции качества кода.

### 6.1 SonarQube Server

```bash
ssh ubuntu@192.168.50.30
```

```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка Docker
sudo apt install -y curl vim openssl docker.io docker-compose
sudo systemctl enable docker --now
docker --version
docker-compose --version
sudo usermod -aG docker $USER
sudo usermod -aG docker ubuntu

# Настройка системы для SonarQube
sudo sysctl -w vm.max_map_count=524288
sudo sysctl -w fs.file-max=131072
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=131072" | sudo tee -a /etc/sysctl.conf

# Создание docker-compose.yml
sudo tee docker-compose.yml > /dev/null <<'EOF'
services:
  db:
    image: postgres:15
    container_name: sonarqube_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: sonar
      POSTGRES_DB: sonarqube
    volumes:
      - sonarqube_db_data:/var/lib/postgresql/data

  sonarqube:
    image: sonarqube:25.1.0-community
    container_name: sonarqube
    restart: unless-stopped
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: sonar
    ports:
      - "9000:9000"
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs

volumes:
  sonarqube_db_data:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
EOF
```

**Примечание**: Используется версия с persistent volumes для сохранения данных.

### 6.2 Запуск SonarQube

```bash
sudo docker-compose up -d
```

Нужно подождать 3-5 минут пока скачаются docker образы sonarqube и postgresql.

**Проверка:**

```bash
sudo docker-compose logs
sudo docker ps
sudo docker logs -f sonarqube
sudo docker logs -f sonarqube_db
```

**Доступ:** `http://sonarqube.local.lab:9000`  
**Логин:** admin/admin (измените после первого входа)

### 6.3 Настройка Webhook для Quality Gate

**Важно**: Настройте webhook для GitLab, чтобы SonarQube отправлял результаты анализа обратно в pipeline.

1. **Укажите адрес хоста SonarQube**:
   - Administration → Configuration → General Settings → Server base URL
   - Значение: `http://sonarqube.local.lab:9000`

2. **Создайте webhook**:
   - Administration → Configuration → Webhooks → Create
   - Name: `gitlab-webhook`
   - URL: `http://gitlab.local.lab/api/v4/ci/sonarqube-webhook`
   - Create

---

## Часть 7: Установка Nexus Repository

Nexus Repository используется для хранения артефактов (Maven, Docker, npm и т.д.)

### 7.1 Установка на выделенной VM

```bash
ssh ubuntu@192.168.50.31
```

```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка Docker
sudo apt install -y curl vim openssl docker.io docker-compose
sudo systemctl enable docker --now
docker --version
docker-compose --version
sudo usermod -aG docker $USER
sudo usermod -aG docker ubuntu

# Запуск Nexus
sudo docker run -d \
  --name nexus \
  --restart=unless-stopped \
  -p 8081:8081 \
  -v nexus-data:/nexus-data \
  sonatype/nexus3

# Ожидание запуска (~15 секунд)
sleep 15

# Получение initial admin password
sudo docker exec nexus cat /nexus-data/admin.password; echo
```

**Доступ:** `http://nexus.local.lab:8081`  
**Логин:** admin + пароль из команды выше

**Примечание**: При установке Nexus по умолчанию создаются 2 репозитория **maven-releases** и **maven-snapshots**. Если их нет, нужно будет создать.

### 7.2 Создание репозиториев

1. Sign in
2. Server administration (шестеренка) → Repositories → Create repository
3. Создайте: `maven-releases` (maven2 hosted)
4. Создайте: `maven-snapshots` (maven2 hosted)

---

## Часть 8: Настройка HAProxy

HAProxy на Gateway обеспечивает реверс-прокси для всех сервисов через доменные имена.

### 8.1 Установка HAProxy

На Gateway (10.0.10.30):

```bash
ssh ubuntu@10.0.10.30

sudo apt update
sudo apt install -y haproxy
```

### 8.2 Резервное копирование конфигурации

```bash
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup
```

### 8.3 Настройка HAProxy

```bash
sudo vim /etc/haproxy/haproxy.cfg
```

Добавьте в конец файла (после defaults):

```
#---------------------------------------------------------------------
# Frontend Configuration
#---------------------------------------------------------------------
frontend http_front
    bind *:80
    mode http
    
    # Логирование
    option httplog
    option forwardfor
    
    # ACL для определения backend по Host header
    acl is_gitlab hdr(host) -i gitlab.local.lab
    acl is_nexus hdr(host) -i nexus.local.lab
    acl is_sonar hdr(host) -i sonarqube.local.lab
    acl is_petclinic hdr(host) -i petclinic.local.lab
    
    # Маршрутизация
    use_backend gitlab_back if is_gitlab
    use_backend nexus_back if is_nexus
    use_backend sonar_back if is_sonar
    use_backend petclinic_back if is_petclinic
    
    # Default backend (опционально)
    default_backend gitlab_back

#---------------------------------------------------------------------
# Backend Configuration
#---------------------------------------------------------------------
backend gitlab_back
    mode http
    balance roundrobin
    option httpchk GET /users/sign_in
    http-check expect status 200
    server gitlab 192.168.50.10:80 check inter 5s fall 3 rise 2

backend nexus_back
    mode http
    balance roundrobin
    option httpchk GET /
    http-check expect status 200
    server nexus 192.168.50.31:8081 check inter 10s fall 3 rise 2

backend sonar_back
    mode http
    balance roundrobin
    option httpchk GET /api/system/status
    http-check expect status 200
    server sonar 192.168.50.30:9000 check inter 10s fall 3 rise 2

backend petclinic_back
    mode http
    balance roundrobin
    option httpchk GET /
    http-check expect status 200 404
    server petclinic 192.168.50.103:80 check inter 5s fall 3 rise 2

#---------------------------------------------------------------------
# Statistics Page (опционально)
#---------------------------------------------------------------------
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE
    # stats auth admin:admin  # Раскомментируйте для Basic Auth
```

### 8.4 Проверка конфигурации

```bash
# Проверка синтаксиса
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Ожидаемый вывод:
# Configuration file is valid
```

### 8.5 Запуск HAProxy

```bash
# Перезапуск HAProxy
sudo systemctl restart haproxy

# Автозапуск
sudo systemctl enable haproxy

# Проверка статуса
sudo systemctl status haproxy

# Проверка логов
sudo journalctl -u haproxy -f
```

### 8.6 Проверка доступа к сервисам

С вашей рабочей машины (после настройки DNS):

```bash
# GitLab
curl -I http://gitlab.local.lab

# Nexus
curl -I http://nexus.local.lab

# SonarQube
curl -I http://sonarqube.local.lab

# PetClinic (будет 404 до деплоя)
curl -I http://petclinic.local.lab
```

Откройте в браузере:

- http://gitlab.local.lab
- http://nexus.local.lab
- http://sonarqube.local.lab

**Страница статистики HAProxy**:

```
http://10.0.10.30:8404/stats
```

---

## Часть 9: Настройка Nexus Repository

### 9.1 Первоначальная настройка

1. Откройте http://nexus.local.lab
2. Click "Sign In" (верхний правый угол)
3. Username: `admin`, Password: (полученный ранее)
4. Следуйте wizard:
   - Change admin password (установите новый)
   - Configure Anonymous Access: Enable (для чтения)
   - Finish

### 9.2 Создание Blob Stores

Settings (шестеренка) → Repository → Blob Stores → Create Blob Store:

1. **maven-releases**
   - Type: File
   - Name: `maven-releases`
   - Path: default

2. **maven-snapshots**
   - Type: File
   - Name: `maven-snapshots`
   - Path: default

### 9.3 Создание Maven Repositories

Settings → Repository → Repositories → Create repository:

#### Maven Release Repository

1. Recipe: `maven2 (hosted)`
2. Name: `maven-hosted-release`
3. Version policy: `Release`
4. Layout policy: `Strict`
5. Blob store: `maven-releases`
6. Deployment policy: `Disable redeploy`
7. Create repository

#### Maven Snapshot Repository

1. Recipe: `maven2 (hosted)`
2. Name: `maven-hosted-snapshot`
3. Version policy: `Snapshot`
4. Layout policy: `Strict`
5. Blob store: `maven-snapshots`
6. Deployment policy: `Allow redeploy`
7. Create repository

### 9.4 Создание Maven Group (опционально, но рекомендуется)

Группа объединяет несколько репозиториев для упрощенного доступа.

1. Recipe: `maven2 (group)`
2. Name: `maven-public-group`
3. Blob store: `default`
4. Member repositories (в порядке приоритета):
   - maven-hosted-release
   - maven-hosted-snapshot
   - maven-central (уже есть по умолчанию)
5. Create repository

### 9.5 Создание пользователя для CI/CD

Settings → Security → Users → Create user:

1. ID: `gitlab-ci`
2. First name: `GitLab`
3. Last name: `CI`
4. Email: `gitlab-ci@local.lab`
5. Status: `Active`
6. Roles: `nx-admin` (или создайте отдельную роль с правами на deploy)
7. Password: (установите надежный пароль)
8. Create user

**Важно**: Сохраните credentials для использования в GitLab CI/CD.

### 9.6 Проверка доступа к репозиториям

Скопируйте URL репозиториев:

- Releases: `http://nexus.local.lab/repository/maven-hosted-release/`
- Snapshots: `http://nexus.local.lab/repository/maven-hosted-snapshot/`
- Group: `http://nexus.local.lab/repository/maven-public-group/`

---

## Часть 10: Настройка SonarQube

### 10.1 Первоначальная настройка

1. Откройте http://sonarqube.local.lab
2. Login: `admin` / Password: `admin`
3. SonarQube попросит сменить пароль - установите новый

### 10.2 Создание проекта

1. Create Project → Manually
2. Project display name: `Spring PetClinic`
3. Project key: `spring-petclinic`
4. Main branch name: `master`
5. Set Up

### 10.3 Генерация токена для CI/CD

1. Provide a token → Generate
2. Token name: `gitlab-ci-token`
3. Type: `Global Analysis Token`
4. Expires in: `90 days`
5. Generate

**Важно**: Скопируйте токен немедленно! Он показывается только один раз.

Пример токена:

```
squ_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8
```

### 10.4 Настройка Quality Gate (опционально)

Quality Gates определяют критерии качества кода.

1. Quality Gates → Create
2. Name: `GitLab CI Gate`
3. Add Condition:
   - On Overall Code:
     - Coverage: is less than `70%` → Warning
     - Duplicated Lines (%): is greater than `3%` → Warning
   - On New Code:
     - Coverage: is less than `80%` → Error
     - Bugs: is greater than `0` → Error
     - Code Smells: is greater than `5` → Warning
4. Save

Привязка к проекту:

1. Projects → Spring PetClinic → Project Settings → Quality Gate
2. Select: `GitLab CI Gate`
3. Save

---

## Часть 11: Настройка GitLab CI/CD

### 11.1 Клонирование Spring PetClinic

На вашей рабочей машине:

```bash
# Клонирование upstream репозитория
git clone https://github.com/spring-projects/spring-petclinic.git
cd spring-petclinic

# Проверка структуры
ls -la
```

### 11.2 Настройка CI/CD переменных в GitLab

1. Откройте http://gitlab.local.lab/root/spring-petclinic
2. Settings → CI/CD → Variables → Expand → Add variable

Создайте следующие переменные:

| Key | Value | Type | Masked | Protected |
|-----|-------|------|--------|-----------|
| `NEXUS_USER` | `gitlab-ci` | Variable | No | No |
| `NEXUS_PASSWORD` | (пароль пользователя) | Variable | Yes | No |
| `NEXUS_URL` | `http://192.168.50.31:8081` | Variable | No | No |
| `SONAR_HOST_URL` | `http://192.168.50.30:9000` | Variable | No | No |
| `SONAR_TOKEN` | `squ_xxx...` (токен из SonarQube) | Variable | Yes | No |
| `CI_REGISTRY` | `https://index.docker.io/v1/` | Variable | No | No |
| `CI_REGISTRY_USER` | (ваш Docker Hub username) | Variable | No | No |
| `CI_REGISTRY_PASSWORD` | (Docker Hub access token) | Variable | Yes | No |
| `KUBECONFIG` | (содержимое ~/.kube/config) | File | No | No |

**Важно для KUBECONFIG**:

На K3s Master:

```bash
cat ~/.kube/config
```

Скопируйте весь вывод и создайте переменную типа **File** в GitLab.

**Важно для Docker Hub**:

1. Зарегистрируйтесь на https://hub.docker.com
2. Account Settings → Security → New Access Token
3. Description: `gitlab-ci`, Access: `Read, Write, Delete`
4. Generate и скопируйте токен

### 11.3 Модификация pom.xml

Откройте `pom.xml` в редакторе:

```bash
vim pom.xml
```

В секции `<properties>` добавьте:

```xml
<properties>
    <!-- Existing properties -->
    <nexus.host.url>http://192.168.50.31:8081</nexus.host.url>
</properties>
```

После закрывающего тега `</repositories>` добавьте:

```xml
<distributionManagement>
    <repository>
        <id>nexus</id>
        <name>Nexus Release Repository</name>
        <url>${nexus.host.url}/repository/maven-hosted-release</url>
    </repository>
    <snapshotRepository>
        <id>nexus</id>
        <name>Nexus Snapshot Repository</name>
        <url>${nexus.host.url}/repository/maven-hosted-snapshot</url>
    </snapshotRepository>
</distributionManagement>
```

Также добавьте зеркало для ускорения сборки (опционально):

```xml
<repositories>
    <repository>
        <id>nexus</id>
        <name>Nexus Repository</name>
        <url>${nexus.host.url}/repository/maven-public-group</url>
        <releases>
            <enabled>true</enabled>
        </releases>
        <snapshots>
            <enabled>true</enabled>
        </snapshots>
    </repository>
</repositories>
```

### 11.4 Создание Maven settings.xml

Создайте директорию и файл:

```bash
mkdir -p .m2
vim .m2/settings.xml
```

Содержимое:

```xml
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              https://maven.apache.org/xsd/settings-1.0.0.xsd">
    <servers>
        <server>
            <id>nexus</id>
            <username>${env.NEXUS_USER}</username>
            <password>${env.NEXUS_PASSWORD}</password>
        </server>
    </servers>
    
    <mirrors>
        <mirror>
            <id>nexus</id>
            <name>Nexus Repository Mirror</name>
            <url>${env.NEXUS_URL}/repository/maven-public-group</url>
            <mirrorOf>*</mirrorOf>
        </mirror>
    </mirrors>
</settings>
```

### 11.5 Создание sonar-project.properties

```bash
vim sonar-project.properties
```

Содержимое:

```properties
# Project identification
sonar.projectKey=spring-petclinic
sonar.projectName=Spring PetClinic
sonar.projectVersion=1.0

# Source and test paths
sonar.sources=src/main/java
sonar.tests=src/test/java

# Java binaries
sonar.java.binaries=target/classes
sonar.java.test.binaries=target/test-classes

# Language
sonar.language=java
sonar.sourceEncoding=UTF-8

# Libraries
sonar.java.libraries=target/classes

# Coverage (JaCoCo)
sonar.coverage.jacoco.xmlReportPaths=target/site/jacoco/jacoco.xml

# Exclusions (optional)
sonar.exclusions=**/test/**,**/resources/**
```

### 11.6 Создание Dockerfile

```bash
vim Dockerfile
```

Содержимое:

```dockerfile
FROM eclipse-temurin:17-jre-alpine

# Metadata
LABEL maintainer="devops@local.lab"
LABEL application="spring-petclinic"

# Create app directory
WORKDIR /app

# Copy JAR file
COPY target/*.jar /app/spring-petclinic.jar

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# Run application
ENTRYPOINT ["java", "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app/spring-petclinic.jar"]
CMD ["--server.port=8080"]
```

### 11.7 Создание Helm Chart

Создайте структуру:

```bash
mkdir -p petclinic-chart/templates
```

**Chart.yaml:**

```bash
cat > petclinic-chart/Chart.yaml <<'EOF'
apiVersion: v2
name: petclinic
description: Spring PetClinic Application Helm Chart
type: application
version: 1.0.0
appVersion: "1.0.0"
maintainers:
  - name: DevOps Team
    email: devops@local.lab
EOF
```

**values.yaml:**

```bash
cat > petclinic-chart/values.yaml <<'EOF'
# Default values for petclinic chart
replicaCount: 2

image:
  repository: yourdockerhubuser/spring-petclinic
  tag: latest
  pullPolicy: Always

service:
  type: LoadBalancer
  loadBalancerIP: 192.168.50.103
  port: 80
  targetPort: 8080

resources:
  limits:
    cpu: 1000m
    memory: 1Gi
  requests:
    cpu: 250m
    memory: 512Mi

livenessProbe:
  enabled: true
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 60
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

readinessProbe:
  enabled: true
  httpGet:
    path: /actuator/health
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80

nodeSelector: {}
tolerations: []
affinity: {}
EOF
```

**templates/deployment.yaml:**

```bash
cat > petclinic-chart/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
    chart: {{ .Chart.Name }}-{{ .Chart.Version }}
    release: {{ .Release.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
      release: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
        release: {{ .Release.Name }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}
          protocol: TCP
        {{- if .Values.livenessProbe.enabled }}
        livenessProbe:
          httpGet:
            path: {{ .Values.livenessProbe.httpGet.path }}
            port: {{ .Values.livenessProbe.httpGet.port }}
          initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds }}
          periodSeconds: {{ .Values.livenessProbe.periodSeconds }}
          timeoutSeconds: {{ .Values.livenessProbe.timeoutSeconds }}
          failureThreshold: {{ .Values.livenessProbe.failureThreshold }}
        {{- end }}
        {{- if .Values.readinessProbe.enabled }}
        readinessProbe:
          httpGet:
            path: {{ .Values.readinessProbe.httpGet.path }}
            port: {{ .Values.readinessProbe.httpGet.port }}
          initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds }}
          periodSeconds: {{ .Values.readinessProbe.periodSeconds }}
          timeoutSeconds: {{ .Values.readinessProbe.timeoutSeconds }}
          failureThreshold: {{ .Values.readinessProbe.failureThreshold }}
        {{- end }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
EOF
```

**templates/service.yaml:**

```bash
cat > petclinic-chart/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
    chart: {{ .Chart.Name }}-{{ .Chart.Version }}
    release: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  {{- if .Values.service.loadBalancerIP }}
  loadBalancerIP: {{ .Values.service.loadBalancerIP }}
  {{- end }}
  selector:
    app: {{ .Chart.Name }}
    release: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
      name: http
EOF
```

**Важно**: Замените `yourdockerhubuser` в `values.yaml` на ваш реальный Docker Hub username.

### 11.8 Создание .gitlab-ci.yml

```bash
vim .gitlab-ci.yml
```

Содержимое (полный production-ready pipeline):

```yaml
# GitLab CI/CD Pipeline for Spring PetClinic
# Stages: build → test → quality → package → dockerize → deploy

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=warn"
  M2_EXTRA: "-s .m2/settings.xml"
  IMAGE_NAME: "spring-petclinic"
  TAG: "$CI_COMMIT_SHORT_SHA"
  DOCKER_IMAGE: "$CI_REGISTRY_USER/$IMAGE_NAME"

# Default image for most jobs
default:
  image: maven:3.9-eclipse-temurin-17
  tags:
    - k8s

# Stages definition
stages:
  - build
  - test
  - quality
  - package
  - dockerize
  - deploy

# Cache Maven dependencies
cache:
  key: "$CI_COMMIT_REF_SLUG"
  paths:
    - .m2/repository/
  policy: pull-push

#---------------------------------------------------------------------
# Stage: Build
#---------------------------------------------------------------------
build:
  stage: build
  script:
    - echo "🔨 Building Spring PetClinic..."
    - mvn $M2_EXTRA clean compile -DskipTests
    - echo "✅ Build completed successfully"
  artifacts:
    paths:
      - target/
    expire_in: 1 hour
  only:
    - branches
    - merge_requests

#---------------------------------------------------------------------
# Stage: Test
#---------------------------------------------------------------------
test:unit:
  stage: test
  script:
    - echo "🧪 Running unit tests..."
    - mvn $M2_EXTRA test
    - echo "✅ Tests completed"
  artifacts:
    when: always
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml
    paths:
      - target/surefire-reports/
      - target/site/jacoco/
    expire_in: 1 week
  dependencies:
    - build
  coverage: '/Total.*?([0-9]{1,3})%/'
  only:
    - branches
    - merge_requests

#---------------------------------------------------------------------
# Stage: Quality Analysis
#---------------------------------------------------------------------
sonarqube:scan:
  stage: quality
  image:
    name: sonarsource/sonar-scanner-cli:latest
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0"  # Full clone for better analysis
  script:
    - echo "🔍 Running SonarQube analysis..."
    - sonar-scanner
      -Dsonar.projectKey=spring-petclinic
      -Dsonar.sources=src/main/java
      -Dsonar.tests=src/test/java
      -Dsonar.java.binaries=target/classes
      -Dsonar.host.url=${SONAR_HOST_URL}
      -Dsonar.login=${SONAR_TOKEN}
      -Dsonar.qualitygate.wait=true
      -Dsonar.qualitygate.timeout=300
    - echo "✅ SonarQube analysis completed"
  dependencies:
    - build
  allow_failure: true
  only:
    - branches
    - merge_requests

#---------------------------------------------------------------------
# Stage: Package
#---------------------------------------------------------------------
package:jar:
  stage: package
  script:
    - echo "📦 Packaging application..."
    - mvn $M2_EXTRA package -DskipTests
    - ls -lh target/*.jar
    - echo "✅ Packaging completed"
  artifacts:
    paths:
      - target/*.jar
    expire_in: 1 week
  dependencies:
    - build
  only:
    - main
    - master
    - develop

deploy:nexus:
  stage: package
  script:
    - echo "📤 Deploying artifacts to Nexus..."
    - mvn $M2_EXTRA deploy -DskipTests
    - echo "✅ Artifacts deployed to Nexus successfully"
  dependencies:
    - package:jar
  only:
    - main
    - master

#---------------------------------------------------------------------
# Stage: Dockerize
#---------------------------------------------------------------------
docker:build:
  stage: dockerize
  image:
    name: gcr.io/kaniko-project/executor:v1.9.0-debug
    entrypoint: [""]
  before_script:
    - echo "🐳 Preparing Docker build..."
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"${CI_REGISTRY}\":{\"auth\":\"$(printf \"%s:%s\" \"${CI_REGISTRY_USER}\" \"${CI_REGISTRY_PASSWORD}\" | base64 | tr -d '\\n')\"}}}" > /kaniko/.docker/config.json
  script:
    - echo "🐳 Building Docker image..."
    - /kaniko/executor
      --context "${CI_PROJECT_DIR}"
      --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
      --destination "${DOCKER_IMAGE}:${TAG}"
      --destination "${DOCKER_IMAGE}:latest"
      --cache=true
      --cache-ttl=24h
    - echo "✅ Docker image built and pushed"
    - echo "Image: ${DOCKER_IMAGE}:${TAG}"
  dependencies:
    - package:jar
  only:
    - main
    - master

#---------------------------------------------------------------------
# Stage: Deploy to Kubernetes
#---------------------------------------------------------------------
deploy:kubernetes:
  stage: deploy
  image:
    name: alpine/k8s:1.28.3
    entrypoint: [""]
  before_script:
    - echo "☸️ Preparing Kubernetes deployment..."
    - apk add --no-cache bash curl
    - curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    - mkdir -p /root/.kube
    - cat $KUBECONFIG > /root/.kube/config
    - chmod 600 /root/.kube/config
    - kubectl cluster-info
    - kubectl get nodes
  script:
    - echo "🚀 Deploying to Kubernetes cluster..."
    - |
      helm upgrade --install petclinic ./petclinic-chart \
        --set image.tag=${TAG} \
        --set image.repository=${DOCKER_IMAGE} \
        --namespace default \
        --create-namespace \
        --wait \
        --timeout 5m \
        --atomic
    - echo "✅ Deployment successful!"
    - echo "Application URL: http://petclinic.local.lab"
    - kubectl get pods -l app=petclinic
    - kubectl get svc petclinic
  environment:
    name: production
    url: http://petclinic.local.lab
    on_stop: stop:kubernetes
  only:
    - main
    - master
  when: manual

# Cleanup deployment
stop:kubernetes:
  stage: deploy
  image:
    name: alpine/k8s:1.28.3
    entrypoint: [""]
  before_script:
    - apk add --no-cache bash curl
    - curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    - mkdir -p /root/.kube
    - cat $KUBECONFIG > /root/.kube/config
  script:
    - helm uninstall petclinic --namespace default || true
    - echo "🗑️ Deployment removed"
  environment:
    name: production
    action: stop
  when: manual
  only:
    - main
    - master
```

### 11.9 Обновление values.yaml с вашим Docker Hub username

```bash
# Замените yourdockerhubuser на ваш username
sed -i 's/yourdockerhubuser/ВАШ_DOCKER_USERNAME/g' petclinic-chart/values.yaml
```

### 11.10 Отправка кода в GitLab

```bash
# Инициализация Git (если еще не инициализирован)
git init

# Добавление remote
git remote remove origin 2>/dev/null || true
git remote add origin http://gitlab.local.lab/root/spring-petclinic.git

# Добавление файлов
git add .

# Коммит
git commit -m "Initial commit: CI/CD pipeline configuration

- Added GitLab CI/CD pipeline with 6 stages
- Configured Maven build with Nexus integration
- Added SonarQube quality gates
- Configured Docker build with Kaniko
- Added Helm chart for Kubernetes deployment
- Configured all required artifacts and caching"

# Push (может потребоваться ввести credentials)
git push -u origin master
```

При запросе credentials:
- Username: `root`
- Password: (пароль root из GitLab)

**Важно**: Если возникнут ошибки аутентификации, создайте Personal Access Token в GitLab:

1. GitLab → Avatar → Preferences → Access Tokens
2. Token name: `git-push`
3. Scopes: `api`, `read_repository`, `write_repository`
4. Create token
5. Используйте токен вместо пароля:
   ```bash
   git push -u origin master
   # Username: root
   # Password: <your-token>
   ```

---

## Часть 12: Установка GitLab Runner в Kubernetes

GitLab Runner будет исполнять CI/CD задачи внутри Kubernetes кластера.

### 12.1 Добавление Helm репозитория GitLab

На K3s Master:

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20

helm repo add gitlab https://charts.gitlab.io
helm repo update

# Проверка
helm search repo gitlab-runner
```

### 12.2 Получение Registration Token

В GitLab:

1. Admin Area (гаечный ключ) → CI/CD → Runners
2. Скопируйте Registration token (под "Set up a shared runner manually")

Пример токена: `GR1348941a1b2c3d4e5f6g7h8i9j0`

### 12.3 Создание namespace

```bash
kubectl create namespace gitlab-runner
```

### 12.4 Подготовка values для Runner

```bash
cat > gitlab-runner-values.yaml <<EOF
# GitLab instance
gitlabUrl: http://192.168.50.10/

# Registration token from GitLab Admin Area
runnerRegistrationToken: "YOUR_REGISTRATION_TOKEN_HERE"

# Runner name
runnerName: k8s-runner

# Unregister runners before termination
unregisterRunners: true

# Concurrent jobs
concurrent: 4

# Check interval
checkInterval: 3

# RBAC
rbac:
  create: true
  clusterWideAccess: false

# Runners configuration
runners:
  # Runner tags
  tags: "k8s,kubernetes,docker"
  
  # Run untagged jobs
  runUntagged: true
  
  # Not locked to specific project
  locked: false
  
  # Kubernetes executor configuration
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "{{.Release.Namespace}}"
        image = "ubuntu:22.04"
        privileged = true
        cpu_request = "100m"
        cpu_limit = "1000m"
        memory_request = "128Mi"
        memory_limit = "1Gi"
        service_cpu_request = "100m"
        service_cpu_limit = "500m"
        service_memory_request = "128Mi"
        service_memory_limit = "512Mi"
        helper_cpu_request = "50m"
        helper_cpu_limit = "200m"
        helper_memory_request = "64Mi"
        helper_memory_limit = "256Mi"
        poll_timeout = 600
        
        # Docker-in-Docker service
        [[runners.kubernetes.services]]
          name = "docker:24-dind"
          alias = "docker"
          command = ["dockerd-entrypoint.sh"]
          
        # Volume mounts
        [[runners.kubernetes.volumes.empty_dir]]
          name = "docker-certs"
          mount_path = "/certs/client"
          medium = "Memory"
          
        [[runners.kubernetes.volumes.empty_dir]]
          name = "docker-cache"
          mount_path = "/var/lib/docker"
          medium = ""

# Resource limits for Runner pod itself
resources:
  limits:
    memory: 512Mi
    cpu: 500m
  requests:
    memory: 256Mi
    cpu: 200m

# Service account
serviceAccount:
  create: true
  name: gitlab-runner

# Pod labels
podLabels:
  app: gitlab-runner

# Pod annotations
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9252"
EOF
```

**Важно**: Замените `YOUR_REGISTRATION_TOKEN_HERE` на реальный токен из GitLab.

### 12.5 Установка GitLab Runner

```bash
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  -f gitlab-runner-values.yaml \
  --timeout 5m

# Мониторинг установки
kubectl get pods -n gitlab-runner -w
```

### 12.6 Проверка регистрации

```bash
# Проверка логов
kubectl logs -n gitlab-runner -l app=gitlab-runner-gitlab-runner -f

# Ожидаемый вывод:
# Registration attempt 1 of 30
# Registering runner... succeeded
# Runner registered successfully.
```

В GitLab:

1. Admin Area → CI/CD → Runners
2. Вы должны увидеть новый runner с тегами `k8s,kubernetes,docker`
3. Кликните на runner для настройки:
   - Description: `Kubernetes Runner`
   - Run untagged jobs: ✓ (отмечено)
   - Lock to current projects: ☐ (снято)
   - Maximum job timeout: `3600` (1 час)
4. Save changes

### 12.7 Тестовый Pipeline

Создайте тестовый файл для проверки runner:

```bash
cat > test-runner.yml <<'EOF'
test_job:
  tags:
    - k8s
  script:
    - echo "Hello from Kubernetes Runner!"
    - uname -a
    - kubectl version --client || echo "kubectl not available"
EOF
```

В GitLab:

1. Repository → + → New file
2. File name: `.gitlab-ci-test.yml`
3. Вставьте содержимое
4. Commit

Или запустите локально:

```bash
git add test-runner.yml
git commit -m "Test runner configuration"
git push origin master
```

Проверьте выполнение в: CI/CD → Pipelines

---

## Часть 13: Запуск и тестирование Pipeline

### 13.1 Триггер Pipeline

Pipeline запускается автоматически при push в master:

```bash
# Внесите небольшое изменение
echo "# CI/CD Pipeline" >> README.md

git add README.md
git commit -m "Trigger CI/CD pipeline"
git push origin master
```

### 13.2 Мониторинг Pipeline

В GitLab:

1. Откройте http://gitlab.local.lab/root/spring-petclinic
2. CI/CD → Pipelines
3. Кликните на последний pipeline

Вы увидите stages:

```
build → test → quality → package → dockerize → deploy
```

**Ожидаемое время выполнения**:
- build: 2-3 минуты
- test: 3-5 минут
- quality (SonarQube): 2-3 минуты
- package: 1-2 минуты
- dockerize: 3-5 минут
- deploy: 2-3 минуты (manual)

**Итого**: ~15-20 минут до manual deployment

### 13.3 Анализ каждого stage

#### Stage: Build

```bash
# Проверка логов
# В GitLab: Pipeline → build job → Logs
```

Ожидаемый вывод:

```
🔨 Building Spring PetClinic...
[INFO] Scanning for projects...
[INFO] Building petclinic 3.2.0-SNAPSHOT
[INFO] Compiling 58 source files
[INFO] BUILD SUCCESS
✅ Build completed successfully
```

#### Stage: Test

```bash
# В GitLab: Pipeline → test:unit job
```

Проверьте:
- Tests run: ~40+ tests
- Failures: 0
- Coverage: должно быть видно в job logs

#### Stage: Quality (SonarQube)

```bash
# В GitLab: Pipeline → sonarqube:scan job
```

После завершения проверьте SonarQube:

1. Откройте http://sonarqube.local.lab
2. Projects → Spring PetClinic
3. Проверьте метрики:
   - Bugs
   - Vulnerabilities
   - Code Smells
   - Coverage
   - Duplications

#### Stage: Package

Два job'а:
- `package:jar` - создает JAR файл
- `deploy:nexus` - загружает артефакт в Nexus

Проверка в Nexus:

1. Откройте http://nexus.local.lab
2. Browse → maven-hosted-snapshot (или release)
3. Найдите: `org/springframework/samples/petclinic/`

#### Stage: Dockerize

```bash
# В GitLab: Pipeline → docker:build job
```

После успешного выполнения проверьте Docker Hub:

1. Откройте https://hub.docker.com
2. Repositories → spring-petclinic
3. Теги: `latest` и `<commit-sha>`

#### Stage: Deploy (Manual)

Deployment требует ручного подтверждения (безопасность production):

1. В Pipeline кликните на `deploy:kubernetes` job
2. Нажмите кнопку **Play** (▶️)
3. Подтвердите deployment

**Мониторинг deployment**:

На K3s Master:

```bash
# Наблюдение за pods
kubectl get pods -l app=petclinic -w

# Проверка deployment
kubectl get deployment petclinic

# Проверка service
kubectl get svc petclinic

# Ожидаемый вывод:
# NAME        TYPE           EXTERNAL-IP      PORT(S)
# petclinic   LoadBalancer   192.168.50.103   80:xxxxx/TCP

# Логи приложения
kubectl logs -l app=petclinic -f
```

### 13.4 Проверка работы приложения

После успешного deployment:

**Через curl**:

```bash
# С K3s Master или Gateway
curl http://192.168.50.103

# Через HAProxy
curl http://petclinic.local.lab
```

**Через браузер**:

Откройте: http://petclinic.local.lab

Вы должны увидеть Spring PetClinic UI:
- Welcome page
- Find Owners
- Veterinarians
- Error (для тестирования error handling)

**Проверка health endpoint**:

```bash
curl http://petclinic.local.lab/actuator/health

# Ожидаемый ответ:
# {"status":"UP"}
```

### 13.5 Troubleshooting Pipeline

#### Проблема: Build fails

```bash
# Проверка Maven зависимостей
mvn dependency:tree

# Проверка settings.xml
cat .m2/settings.xml

# Проверка доступности Nexus
curl -I http://192.168.50.31:8081
```

#### Проблема: SonarQube scan fails

```bash
# Проверка доступности SonarQube
curl http://192.168.50.30:9000/api/system/status

# Проверка токена
echo $SONAR_TOKEN  # в job logs (masked)

# В SonarQube: Administration → Projects → Management
# Проверьте существование проекта spring-petclinic
```

#### Проблема: Docker push fails

```bash
# Проверка Docker Hub credentials
# В GitLab: Settings → CI/CD → Variables
# Убедитесь, что CI_REGISTRY_USER и CI_REGISTRY_PASSWORD корректны

# Попробуйте локально
docker login
docker pull $CI_REGISTRY_USER/spring-petclinic:latest
```

#### Проблема: Kubernetes deployment fails

```bash
# Проверка kubeconfig
kubectl get nodes  # должно работать

# Проверка namespace
kubectl get ns

# Проверка RBAC
kubectl auth can-i create deployments --namespace=default

# Проверка образа
kubectl describe pod <pod-name> | grep -A 5 Events

# Логи failed pod
kubectl logs <pod-name>
```

### 13.6 Rollback deployment

Если deployment failed или приложение работает некорректно:

```bash
# Откат Helm release
helm rollback petclinic 0  # 0 = previous revision

# Или удаление deployment
helm uninstall petclinic --namespace default

# Проверка
kubectl get pods
```

В GitLab также можно использовать:

1. Deployments → Environments → production
2. Re-deploy → выберите предыдущий успешный deployment
3. Rollback

---

## Часть 14: Мониторинг и отладка

### 14.1 Мониторинг GitLab

#### Проверка статуса компонентов

На GitLab VM:

```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10

# Статус всех сервисов
sudo gitlab-ctl status

# Ожидаемый вывод (все должны быть "run"):
# run: gitaly: ...
# run: gitlab-workhorse: ...
# run: logrotate: ...
# run: nginx: ...
# run: postgres: ...
# run: puma: ...
# run: redis: ...
# run: sidekiq: ...

# Проверка логов
sudo gitlab-ctl tail

# Конкретный сервис
sudo gitlab-ctl tail puma
```

#### Проверка производительности

```bash
# Использование ресурсов
sudo gitlab-ctl service-list
free -h
df -h

# Top процессов
htop

# Проверка базы данных
sudo gitlab-psql -c "SELECT COUNT(*) FROM projects;"
sudo gitlab-psql -c "SELECT COUNT(*) FROM ci_builds;"
```

#### GitLab Logs

```bash
# Основные логи
sudo tail -f /var/log/gitlab/gitlab-rails/production.log
sudo tail -f /var/log/gitlab/gitlab-rails/api_json.log
sudo tail -f /var/log/gitlab/nginx/gitlab_access.log
sudo tail -f /var/log/gitlab/sidekiq/current
```

### 14.2 Мониторинг Kubernetes

#### Проверка состояния кластера

```bash
# Подключение к Master
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20

# Nodes
kubectl get nodes -o wide
kubectl describe node k3s-master

# Pods по всем namespace
kubectl get pods --all-namespaces -o wide

# Events
kubectl get events --all-namespaces --sort-by='.lastTimestamp'

# Top команды (требует metrics-server)
kubectl top nodes
kubectl top pods --all-namespaces
```

#### Проверка конкретных компонентов

```bash
# GitLab Runner
kubectl get pods -n gitlab-runner
kubectl logs -n gitlab-runner -l app=gitlab-runner-gitlab-runner -f

# PetClinic (если задеплоен)
kubectl get pods -l app=petclinic
kubectl logs -l app=petclinic -f --all-containers=true
```

#### Проверка Services и LoadBalancers

```bash
# Все services
kubectl get svc --all-namespaces

# MetalLB статус
kubectl get ipaddresspool -n metallb-system
kubectl logs -n metallb-system -l app=metallb -f

# Проверка конкретного service
kubectl describe svc petclinic
```

#### Persistent Volumes

```bash
# PV и PVC
kubectl get pv
kubectl get pvc --all-namespaces

# Детали
kubectl describe pvc -n sonarqube
```

### 14.3 Мониторинг сети

#### На Gateway

```bash
ssh ubuntu@10.0.10.30

# Проверка портов
sudo netstat -tulpn | grep -E ':(80|443|53|8404)'

# Проверка HAProxy
sudo systemctl status haproxy
curl http://10.0.10.30:8404/stats

# Проверка BIND9
sudo systemctl status bind9
dig @127.0.0.1 gitlab.local.lab
dig @127.0.0.1 nexus.local.lab

# Мониторинг соединений
sudo tcpdump -i eth0 port 80 -n

# iptables rules
sudo iptables -L -v -n
sudo iptables -t nat -L -v -n
```

#### Проверка связности

```bash
# С Gateway
ping -c 3 192.168.50.10  # GitLab
ping -c 3 192.168.50.20  # K3s Master
ping -c 3 192.168.50.30  # SonarQube
ping -c 3 192.168.50.31  # Nexus

# DNS resolution
nslookup gitlab.local.lab
nslookup sonarqube.local.lab

# HTTP проверка
curl -I http://gitlab.local.lab
curl -I http://nexus.local.lab
curl -I http://sonarqube.local.lab
```

---

## Часть 15: Дополнительные настройки

### 15.1 Backup и Disaster Recovery

#### Backup скрипт для Kubernetes

На K3s Master создайте:

```bash
sudo vim /usr/local/bin/k8s-backup.sh
```

Содержимое:

```bash
#!/bin/bash

BACKUP_DIR="/home/ubuntu/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="$BACKUP_DIR/k8s-backup-$DATE"

mkdir -p "$BACKUP_PATH"

echo "Starting Kubernetes backup at $(date)"

# Backup all resources
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    echo "Backing up namespace: $ns"
    mkdir -p "$BACKUP_PATH/$ns"
    
    for kind in deployment statefulset service configmap secret pvc