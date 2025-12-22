# Spring PetClinic CI/CD Pipeline на Proxmox

В этой записке описывается развертывание production-ready CI/CD pipeline с GitLab, Kubernetes, Maven, Nexus, SonarQube на домашнем Proxmox сервере с полной сетевой изоляцией.

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
<img width="1919" height="987" alt="image" src="https://github.com/user-attachments/assets/8fa352de-f3ec-4055-ba3e-fb0bb5bc0a20" />



Оригинальный репозиторий:
https://github.com/kunchalavikram1427/gitlab-ci-spring-petclinic

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
       ├─→ Router (10.0.10.1)
       │
       └─→ Proxmox Host (10.0.10.200)
                │
                ├─→ vmbr0 (Внешняя сеть: 10.0.10.0/24)
                │        │
                │        └─→ Gateway VM (10.0.10.30) ← Доступ извне
                │                 │
                │                 │ (NAT, DNS, HAProxy, Jump)
                │                 │
                └─→ vmbr1 (Внутренняя сеть: 192.168.50.0/24)
                          │
                          ├─→ Gateway VM (192.168.50.1)
                          ├─→ GitLab (192.168.50.10)
                          ├─→ K3s Master (192.168.50.20)
                          ├─→ K3s Worker-1 (192.168.50.21)
                          ├─→ K3s Worker-2 (192.168.50.22)
                          ├─→ SonarQube (192.168.50.30)
                          ├─→ Nexus (192.168.50.31)
                          └─→ MetalLB Services (192.168.50.100+)
```

---

## Часть 1: Подготовка виртуальных машин

### 1.1 Требования к ресурсам VM

| VM | CPU | RAM | Disk | Назначение |IP адрес внут./внеш. |
|----|-----|-----|------|-----------|-----------|
| Gateway | 2 | 4GB | 20GB | NAT, DNS (BIND), HAProxy, Jump host | 192.168.50.1 / 10.0.10.30 |
| GitLab | 4 | 8GB | 50GB | Git repository, CI/CD orchestration |192.168.50.10  |
| K3s Master | 2 | 4GB | 40GB | Kubernetes control plane |192.168.50.20|
| K3s Worker-1 | 2 | 8GB | 60GB | Kubernetes workloads  |192.168.50.21|
| K3s Worker-2 | 2 | 8GB | 60GB | Kubernetes workloads |192.168.50.22|
| SonarQube | 2 | 4GB | 40GB | Code Scaning |192.168.50.30|
| Nexus | 2 | 4GB | 100GB | Nexus repositoru |192.168.50.31|

**Итого**: 12 vCPU, 32GB RAM, 230GB Disk

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
#Internal DevOps network
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

В папке Terraform все файлы по созданию ВМ и шаблона для этого проекта

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

**Важно**: Имена интерфейсов могут отличаться (eth0, enp0s18, ens8 и т.д.). Используйте актуальные имена в дальнейших командах.

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

# Останов systemd-resolved (конфликтует с BIND)
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf
```

#### 2.4.2 Настройка основной конфигурации

Редактирование главного конфигурационного файла:

```bash
sudo vim /etc/bind/named.conf.options
```

Замените содержимое на:

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
sudo vim /etc/bind/named.conf.local
```

Добавьте:

```
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
sudo vim /etc/bind/zones/db.local.lab
```

Содержимое:

```
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
k3s-worker-1     IN      A       192.168.50.21
k3s-worker-2     IN      A       192.168.50.22
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
sudo vim /etc/bind/zones/db.192.168.50
```

Содержимое:

```
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
31      IN      PTR     sonarqube.local.lab.
32      IN      PTR     nexus.local.lab.
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


#### Ручная настройка jumphost


```bash
ssh admin@jumphost.local.lab
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

# Netplan для jumphost (2 интерфейса)
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
# На jumphost создайте файл set-dns.sh
cat > /tmp/set-dns.sh <<'EOF'
#!/bin/bash

echo "Настройка DNS и маршрутизации..."

# Получение текущего IP
CURRENT_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Определение gateway
if [[ $CURRENT_IP == 192.168.50.* ]]; then
    GATEWAY="192.168.50.1"  # cf-tunnel как gateway
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
# На jumphost создайте список хостов (только внутренние VM)
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
    scp /tmp/set-dns.sh admin@${host}:/tmp/
    ssh admin@${host} "sudo bash /tmp/set-dns.sh"
    echo ""
done

# Для VM с двумя интерфейсами (jumphost уже настроен вручную)
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
Соединение на внешней машине из 10.0.10.0/24 с внутренними 192.168.50.0.24:
```bash
# С внутренних VM (через jump)
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10
```
### Настройка SSH доступа на все VM
Копирование публичного ключа
```bash
# Создаем приватный и публичный ключ на Gateway
ssh-keygen -t ed25519 -C "devops@local.lab" -f ~/.ssh/proxmox_devops

# Копирование публичного ключа на Gateway
ssh-copy-id -i ~/.ssh/proxmox_devops.pub admin@10.0.10.30

# С Gateway копирование публичного ключа на все внутренние VM
for host in 192.168.50.{10,20,21,22,30,31}; do
    ssh-copy-id -i ~/.ssh/proxmox_devops.pub admin@${host}
done

# Отключение password authentication
for host in 10.0.10.30 192.168.50.{10,20,21,22,30,31}; do
    ssh admin@${host} 'sudo sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config'
    ssh admin@${host} 'sudo systemctl restart sshd'
done

# Создаем файл ~/.ssh/config или добавляем в его конец настройки, чтобы не вводить постоянно ssh -i public_key admin@gitlab.local.lab
cat >> ~/.ssh/config <<EOF
Host gitlab.local.lab k3s-master.local.lab
    User admin
    IdentityFile ~/.ssh/proxmox_devops
    IdentitiesOnly yes
EOF
# Установливаем правильные права:
chmod 600 ~/.ssh/config
```
Не обязательный пример добавления по отдельности каждый хост:
```bash
cat >> ~/.ssh/config <<EOF
# Или отдельно для каждого хоста
Host gitlab.local.lab
    User admin
    IdentityFile ~/.ssh/proxmox_devops

Host k3s-master.local.lab  
    User admin
    IdentityFile ~/.ssh/proxmox_devops
EOF
```
Проверяем вход по ключу с Jumphost:
```bash
ssh gitlab.local.lab      # автоматически подставляем  правильный ключ без опции -i <key_name>
ssh k3s-master.local.lab  # автоматически подставляем правильный ключ без опции -i <key_name>
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

nginx['client_max_body_size'] = '500m'
gitlab_rails['max_attachment_size'] = 500

sidekiq['max_concurrency'] = 10

# Отключение встроенного мониторинга (экономия RAM)
prometheus_monitoring['enable'] = false
# grafana['enable'] = false

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

Установка kubectl:
Установка инструментов:

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# ArgoCD CLI
ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/
argocd version --client

# k9s (TUI для K8s)
K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d '"' -f 4)
wget https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz
sudo mv k9s /usr/local/bin/
rm k9s_Linux_amd64.tar.gz LICENSE README.md

# kubectx и kubens
sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
```

Копирование kubeconfig:

```bash
mkdir -p ~/.kube

sudo scp admin@k3s-master.local.lab:/etc/rancher/k3s/k3s.yaml ~/.kube/config
# Если ошибка permission denied, от на k3s-master вводим команду sudo chmod 644 /etc/rancher/k3s/k3s.yaml
# После копирования, возвращаем права sudo chmod 600 /etc/rancher/k3s/k3s.yaml

# Замена адреса сервера, ставим IP, если поставить DNS имя , будет ругаться на сертификат
sed -i 's/127.0.0.1/192.168.50.20/g' ~/.kube/config

# Установка правильных прав
chmod 600 ~/.kube/config

# Проверка доступа
kubectl get nodes
kubectl cluster-info

# Создание алиасов
cat >> ~/.bashrc <<EOF

# Kubernetes aliases
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kga='kubectl get all'
alias kdp='kubectl describe pod'
alias kl='kubectl logs'
alias kex='kubectl exec -it'
EOF

source ~/.bashrc
```

Тестирование:

```bash
k get nodes
k get pods -A
k9s  # Интерактивный интерфейс
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
5. **Увеличение размера вложения**
   - Admin Area > Settings > CI/CD > Locate the "Maximum build artifact size"
  
     
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

### 4.3 Настройка kubectl для пользователя admin

```bash
# Создание .kube директории
mkdir -p ~/.kube

# Копирование kubeconfig
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown admin:admin ~/.kube/config

# Проверка доступа
kubectl get nodes
kubectl get pods --all-namespaces
```

### 4.4 Установка K3s Worker-1

Подключение:

```bash
ssh -J admin@10.0.10.30 admin@192.168.50.21
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
ssh -J admin@10.0.10.30 admin@192.168.50.22
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
# k3s-worker1   Ready    <none>                 5m      v1.27.x+k3s1   192.168.50.21
# k3s-worker2   Ready    <none>                 2m      v1.27.x+k3s1   192.168.50.22

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
Подключение к Master
```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20
```
```bash
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

### SonarQube Server

```bash
ssh ubuntu@192.168.50.30
```
```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка Docker
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl vim openssl docker.io docker-compose
sudo systemctl enable docker --now
docker --version
docker-compose --version
sudo usermod -aG docker $USER
sudo usermod -aG docker ubuntu
sudo usermod -aG docker admin
sudo getent group docker 

# Настройка системы для SonarQube
sudo sysctl -w vm.max_map_count=524288
sudo sysctl -w fs.file-max=131072
echo "vm.max_map_count=524288" | sudo tee -a /etc/sysctl.conf
echo "fs.file-max=131072" | sudo tee -a /etc/sysctl.conf

sudo tee docker-compose.yml > /dev/null <<'EOF'
services:
  db:
    image: postgres:15
    restart: unless-stopped
    container_name: sonarqube_db
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: sonar
      POSTGRES_DB: sonarqube
  sonarqube:
    image: sonarqube:25.10.0.114319-community
    restart: unless-stopped
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonarqube
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: sonar
    ports:
      - "9000:9000"

EOF
```


**Примечание:**    По умолчанию контейнер SonarQube и Postgresql стирают свои данные при перезапуске (sudo docker-compose down).  Поэтому нужно создать другой yaml файл с persistent volume, то есть хранением данных на хостовой машине. Вот пример постоянной машины Sonarqube:
```
sudo tee docker-compose.yml > /dev/null <<EOF
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
    image: sonarqube:25.10.0.114319-community
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


### Запуск SonarQube если он не запущен

```bash
sudo docker-compose up -d
```
Нужно пождать 3-5 минут пока скачаются docker образы sonarqube и postgresql.

**Проверка:**
```bash
sudo docker-compose logs
sudo docker ps
sudo docker logs -f admin-sonarqube-1
sudo docker logs -f sonarqube_db

```
**Настройка Webhook для этапа QualityGate:**
Нужно обязательно настроить веб хуки для Jenkins, когда код проекта будет проверен, SonarQube отправит вебхук в Jenkins, что проверка завршена. В противном случае,задание Quality Gate будет висеть минут 5 и потом вывалится в ошибку, так как Jenkins не получил веб хук от SonarQube.


- **Указываем адрес хоста SonarQube чтобы при отправке webhook формировался верный json:** Administration → Congiguration → General Settings → Server base URL → http://sonar.local.lab:9000
- **Создаем вебхук идем в меню Administration:**
Administration -> Configuration -> Webhooks -> Create
Project -> Boardgame -> Project Settings -> Webhooks -> Create
- Name: jenkins-webhook
- URL: http://jenkins.local.lab:8080/sonarqube-webhook/
- Create

**Также можно повешать вебхуки на отдельный проект**
Project -> Boardgame -> Project Settings -> Webhooks -> Create



<img width="1100" height="755" alt="image" src="https://github.com/user-attachments/assets/ae38f361-e5f3-49be-8548-fa819e3c0cc0" />
Веб интерфейс sonarqube.

**Доступ:** `https://sonar.your-domain.com:9000`  
**Логин:** admin/admin (измените после первого входа)

### 7. Nexus Repository

Nexus Repository  используется для хранентя артефактов (npm, docker и т.д.)

```bash
ssh ubuntu@192.168.50.31
```

```bash


# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка Docker
sudo apt update && sudo apt upgrade -y
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

# Ожидание запуска (~15  секунд)
sleep 15

# Получение initial admin password
sudo docker exec nexus cat /nexus-data/admin.password; echo
```

**Доступ:** `https://nexus.your-domain.com:8081`  
**Логин:** admin + пароль из команды выше

Примечание: При установке Nexus по умолчанию создаются 2 репозитория **maven-releases** и **maven-snapshots**. Если их нет, нужно будет создать. 

**Создание репозиториев:**
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
```
```bash
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
    http-check expect status 200
    # http-check expect status 200 404
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
curl -I http://nexus.local.lab:8081

# SonarQube
curl -I http://sonarqube.local.lab:9000

# PetClinic (будет 404 до деплоя)
curl -I http://petclinic.local.lab
```

Откройте в браузере:

- http://gitlab.local.lab
- http://nexus.local.lab:8081
- http://sonarqube.local.lab:9000

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

### 9.5 Создание Docker Registry (опционально)

Если планируете хранить Docker образы в Nexus:

1. Recipe: `docker (hosted)`
2. Name: `docker-hosted`
3. HTTP: `8082`
4. Enable Docker V1 API: снять галочку
5. Blob store: `default`
6. Deployment policy: `Allow redeploy`
7. Create repository

**Важно**: Для Docker registry потребуется дополнительный Service в Kubernetes и настройка HAProxy.

### 9.6 Создание пользователя для CI/CD

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

### 9.7 Проверка доступа к репозиториям

Скопируйте URL репозиториев:

- Releases: `http://nexus.local.lab/repository/maven-hosted-release/`
- Snapshots: `http://nexus.local.lab/repository/maven-hosted-snapshot/`
- Group: `http://nexus.local.lab/repository/maven-public-group/`

---

## Часть 10: Настройка SonarQube

### 10.1 Первоначальная настройка

1. Откройте http://sonarqube.local.lab:9000
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

### 10.5 Настройка Webhooks для GitLab (опционально)

Для автоматического декорирования MR результатами SonarQube:

1. Administration → Configuration → General Settings → DevOps Platform Integrations
2. GitLab:
   - Configuration name: `GitLab Local`
   - GitLab URL: `http://gitlab.local.lab`
   - Personal Access Token: (создайте в GitLab)
3. Save

### 10.6 Установка SonarScanner (локально для тестов)

На вашей рабочей машине:

**Linux/Mac:**

```bash
wget https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
```

Проверка:

```bash
sonar-scanner --version
```

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
Примечание: как вариант можно импортировать проект "Pet Clinic" сразу в gitlab. Для этого нужно включить опцию "Импортирование" в глобальных настройках (Settings -> General -> Import and export settings -> проставить галочки).

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
| `CI_REGISTRY_IMAGE` | `almsys/spring-petclinic` | Variable | No | No |
| `CI_REGISTRY_USER` | (ваш Docker Hub username) | Variable | No | No |
| `CI_REGISTRY_PASSWORD` | (Docker Hub access token) | Variable | Yes | No |
| `KUBECONFIG` | (содержимое ~/.kube/config) | File | No | No |

Примечание: Переменные настраиваются глобально как в примере, также можно настроить локальные в каждом проекте.

**Важно для KUBECONFIG**:

На K3s Master:

```bash
cat ~/.kube/config
```

Скопируйте весь вывод и создайте переменную типа **File** в GitLab. Внутри файла есть IP адрес 127.0.0.1, поменяйте его на адрес k3s master node (192.168.50.20)

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
Полный файл pom.xml:
```yaml

<?xml version="1.0" encoding="UTF-8"?>
<project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://maven.apache.org/POM/4.0.0" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>org.springframework.samples</groupId>
  <artifactId>spring-petclinic</artifactId>
  <version>2.0</version>
  <packaging>war</packaging>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>2.6.2</version>
  </parent>
  <name>petclinic</name>
  <properties>
    <!-- Generic properties -->
    <java.version>1.8</java.version>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <project.reporting.outputEncoding>UTF-8</project.reporting.outputEncoding>
    <!-- Web dependencies -->
    <webjars-bootstrap.version>5.1.3</webjars-bootstrap.version>
    <webjars-font-awesome.version>4.7.0</webjars-font-awesome.version>
    <jacoco.version>0.8.5</jacoco.version>
    <node.version>v8.11.1</node.version>
    <nohttp-checkstyle.version>0.0.4.RELEASE</nohttp-checkstyle.version>
    <spring-format.version>0.0.27</spring-format.version>
    <nexus.host.url>http://nexus.local.lab:8081</nexus.host.url>
  </properties>
  <dependencies>
    <!-- Spring and Spring Boot dependencies -->
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-cache</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-validation</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-thymeleaf</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
    <!-- Databases - Uses H2 by default -->
    <dependency>
      <groupId>com.h2database</groupId>
      <artifactId>h2</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>mysql</groupId>
      <artifactId>mysql-connector-java</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>org.postgresql</groupId>
      <artifactId>postgresql</artifactId>
      <scope>runtime</scope>
    </dependency>
    <!-- caching -->
    <dependency>
      <groupId>javax.cache</groupId>
      <artifactId>cache-api</artifactId>
    </dependency>
    <dependency>
      <groupId>org.ehcache</groupId>
      <artifactId>ehcache</artifactId>
    </dependency>
    <!-- webjars -->
    <dependency>
      <groupId>org.webjars</groupId>
      <artifactId>webjars-locator-core</artifactId>
    </dependency>
    <dependency>
      <groupId>org.webjars.npm</groupId>
      <artifactId>bootstrap</artifactId>
      <version>${webjars-bootstrap.version}</version>
    </dependency>
    <dependency>
      <groupId>org.webjars.npm</groupId>
      <artifactId>font-awesome</artifactId>
      <version>${webjars-font-awesome.version}</version>
    </dependency>
    <!-- end of webjars -->
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-devtools</artifactId>
      <optional>true</optional>
    </dependency>
  </dependencies>
  <distributionManagement>
    <repository>
      <id>nexus-releases</id>
      <name>Maven Release Repository</name>
      <url>${nexus.host.url}/repository/maven-releases/</url>
    </repository>
    <snapshotRepository>
      <id>nexus-snapshots</id>
      <name>Maven Snapshot Repository</name>
      <url>${nexus.host.url}/repository/maven-snapshots/</url>
    </snapshotRepository>
  </distributionManagement>  
  <build>
    <plugins>
      <plugin>
        <groupId>io.spring.javaformat</groupId>
        <artifactId>spring-javaformat-maven-plugin</artifactId>
        <version>${spring-format.version}</version>
        <executions>
          <execution>
            <phase>validate</phase>
            <goals>
              <goal>validate</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-checkstyle-plugin</artifactId>
        <configuration>
          <skip>true</skip>
        </configuration>
        <version>3.1.1</version>
        <dependencies>
          <dependency>
            <groupId>com.puppycrawl.tools</groupId>
            <artifactId>checkstyle</artifactId>
            <version>8.32</version>
          </dependency>
          <dependency>
            <groupId>io.spring.nohttp</groupId>
            <artifactId>nohttp-checkstyle</artifactId>
            <version>${nohttp-checkstyle.version}</version>
          </dependency>
        </dependencies>
        <executions>
          <execution>
            <id>nohttp-checkstyle-validation</id>
            <phase>validate</phase>
            <configuration>
              <configLocation>src/checkstyle/nohttp-checkstyle.xml</configLocation>
              <suppressionsLocation>src/checkstyle/nohttp-checkstyle-suppressions.xml</suppressionsLocation>
              <encoding>UTF-8</encoding>
              <sourceDirectories>${basedir}</sourceDirectories>
              <includes>**/*</includes>
              <excludes>**/.git/**/*,**/.idea/**/*,**/target/**/,**/.flattened-pom.xml,**/*.class</excludes>
            </configuration>
            <goals>
              <goal>check</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
        <executions>
          <execution>
            <!-- Spring Boot Actuator displays build-related information
              if a META-INF/build-info.properties file is present -->
            <goals>
              <goal>build-info</goal>
            </goals>
            <configuration>
              <additionalProperties>
                <encoding.source>${project.build.sourceEncoding}</encoding.source>
                <encoding.reporting>${project.reporting.outputEncoding}</encoding.reporting>
                <java.source>${maven.compiler.source}</java.source>
                <java.target>${maven.compiler.target}</java.target>
              </additionalProperties>
            </configuration>
          </execution>
        </executions>
      </plugin>
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>${jacoco.version}</version>
        <executions>
          <execution>
            <goals>
              <goal>prepare-agent</goal>
            </goals>
          </execution>
          <execution>
            <id>report</id>
            <phase>prepare-package</phase>
            <goals>
              <goal>report</goal>
            </goals>
          </execution>
        </executions>
      </plugin>
      <!-- Spring Boot Actuator displays build-related information if a git.properties
        file is present at the classpath -->
      <plugin>
        <groupId>pl.project13.maven</groupId>
        <artifactId>git-commit-id-plugin</artifactId>
        <executions>
          <execution>
            <goals>
              <goal>revision</goal>
            </goals>
          </execution>
        </executions>
        <configuration>
          <verbose>true</verbose>
          <dateFormat>yyyy-MM-dd'T'HH:mm:ssZ</dateFormat>
          <generateGitPropertiesFile>true</generateGitPropertiesFile>
          <generateGitPropertiesFilename>${project.build.outputDirectory}/git.properties
          </generateGitPropertiesFilename>
          <failOnNoGitDirectory>false</failOnNoGitDirectory>
          <failOnUnableToExtractRepoInfo>false</failOnUnableToExtractRepoInfo>
        </configuration>
      </plugin>
    </plugins>
  </build>
  <licenses>
    <license>
      <name>Apache License, Version 2.0</name>
      <url>https://www.apache.org/licenses/LICENSE-2.0</url>
    </license>
  </licenses>
  <repositories>
    <repository>
      <id>spring-snapshots</id>
      <name>Spring Snapshots</name>
      <url>https://repo.spring.io/snapshot</url>
      <snapshots>
        <enabled>true</enabled>
      </snapshots>
    </repository>
    <repository>
      <id>spring-milestones</id>
      <name>Spring Milestones</name>
      <url>https://repo.spring.io/milestone</url>
      <snapshots>
        <enabled>false</enabled>
      </snapshots>
    </repository>
  </repositories>
  
  <pluginRepositories>
    <pluginRepository>
      <id>spring-snapshots</id>
      <name>Spring Snapshots</name>
      <url>https://repo.spring.io/snapshot</url>
      <snapshots>
        <enabled>true</enabled>
      </snapshots>
    </pluginRepository>
    <pluginRepository>
      <id>spring-milestones</id>
      <name>Spring Milestones</name>
      <url>https://repo.spring.io/milestone</url>
      <snapshots>
        <enabled>false</enabled>
      </snapshots>
    </pluginRepository>
  </pluginRepositories>
  <profiles>
    <profile>
      <id>css</id>
      <build>
        <plugins>
          <plugin>
            <groupId>org.apache.maven.plugins</groupId>
            <artifactId>maven-dependency-plugin</artifactId>
            <executions>
              <execution>
                <id>unpack</id>
                <?m2e execute onConfiguration,onIncremental?>
                <phase>generate-resources</phase>
                <goals>
                  <goal>unpack</goal>
                </goals>
                <configuration>
                  <artifactItems>
                    <artifactItem>
                      <groupId>org.webjars.npm</groupId>
                      <artifactId>bootstrap</artifactId>
                      <version>${webjars-bootstrap.version}</version>
                    </artifactItem>
                  </artifactItems>
                  <outputDirectory>${project.build.directory}/webjars</outputDirectory>
                </configuration>
              </execution>
            </executions>
          </plugin>
          <plugin>
            <groupId>com.gitlab.haynes</groupId>
            <artifactId>libsass-maven-plugin</artifactId>
            <version>0.2.26</version>
            <executions>
              <execution>
                <phase>generate-resources</phase>
                <?m2e execute onConfiguration,onIncremental?>
                <goals>
                  <goal>compile</goal>
                </goals>
              </execution>
            </executions>
            <configuration>
              <inputPath>${basedir}/src/main/scss/</inputPath>
              <outputPath>${basedir}/src/main/resources/static/resources/css/</outputPath>
              <includePath>${project.build.directory}/webjars/META-INF/resources/webjars/bootstrap/${webjars-bootstrap.version}/scss/</includePath>
            </configuration>
          </plugin>
        </plugins>
      </build>
    </profile>
    <profile>
      <id>m2e</id>
      <activation>
        <property>
          <name>m2e.version</name>
        </property>
      </activation>
      <build>
        <pluginManagement>
          <plugins>
            <!-- This plugin's configuration is used to store Eclipse m2e settings
   only. It has no influence on the Maven build itself. -->
            <plugin>
              <groupId>org.eclipse.m2e</groupId>
              <artifactId>lifecycle-mapping</artifactId>
              <version>1.0.0</version>
              <configuration>
                <lifecycleMappingMetadata>
                  <pluginExecutions>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>org.apache.maven.plugins</groupId>
                        <artifactId>maven-checkstyle-plugin</artifactId>
                        <versionRange>[1,)</versionRange>
                        <goals>
                          <goal>check</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore />
                      </action>
                    </pluginExecution>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>org.springframework.boot</groupId>
                        <artifactId>spring-boot-maven-plugin</artifactId>
                        <versionRange>[1,)</versionRange>
                        <goals>
                          <goal>build-info</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore />
                      </action>
                    </pluginExecution>
                    <pluginExecution>
                      <pluginExecutionFilter>
                        <groupId>io.spring.javaformat</groupId>
                        <artifactId>spring-javaformat-maven-plugin</artifactId>
                        <versionRange>[0,)</versionRange>
                        <goals>
                          <goal>validate</goal>
                        </goals>
                      </pluginExecutionFilter>
                      <action>
                        <ignore />
                      </action>
                    </pluginExecution>
                  </pluginExecutions>
                </lifecycleMappingMetadata>
              </configuration>
            </plugin>
          </plugins>
        </pluginManagement>
      </build>
    </profile>
  </profiles>
</project>
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
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 
                              http://maven.apache.org/xsd/settings-1.0.0.xsd">
    
    <!-- Mirror - ПЕРЕНАПРАВЛЯЕТ ВСЕ ЗАПРОСЫ В NEXUS -->
    <mirrors>
        <mirror>
            <id>nexus-mirror</id>
            <name>Nexus Repository Manager</name>
            <url>http://nexus.local.lab:8081/repository/maven-public/</url>
            <mirrorOf>*</mirrorOf>
        </mirror>
    </mirrors>
    
    <!-- Servers - ДЛЯ ДЕПЛОЯ АРТЕФАКТОВ -->
    <servers>
        <server>
            <id>nexus-releases</id>
            <username>${env.NEXUS_USER}</username>
            <password>${env.NEXUS_PASSWORD}</password>
        </server>
        <server>
            <id>nexus-snapshots</id>
            <username>${env.NEXUS_USER}</username>
            <password>${env.NEXUS_PASSWORD}</password>
        </server>
    </servers>
    
    <!-- Profiles - ДОПОЛНИТЕЛЬНЫЕ НАСТРОЙКИ -->
    <profiles>
        <profile>
            <id>nexus</id>
            <repositories>
                <repository>
                    <id>central</id>
                    <url>http://nexus.local.lab:8081/repository/maven-public/</url>
                    <releases><enabled>true</enabled></releases>
                    <snapshots><enabled>true</enabled></snapshots>
                </repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository>
                    <id>central</id>
                    <url>http://nexus.local.lab:8081/repository/maven-public/</url>
                    <releases><enabled>true</enabled></releases>
                    <snapshots><enabled>true</enabled></snapshots>
                </pluginRepository>
            </pluginRepositories>
        </profile>
    </profiles>
    
    <!-- Active Profiles - АКТИВИРУЕМ NEXUS -->
    <activeProfiles>
        <activeProfile>nexus</activeProfile>
    </activeProfiles>
    
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

# Copy WAR file
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
default:
  image: maven:3.8.2-openjdk-11
  
variables:
  M2_EXTRA_OPTIONS: "-s .m2/settings.xml"
  IMAGE_NAME: spring-petclinic
  TAG: $CI_COMMIT_SHA
  
stages:
  - check
  - build
  - sonarscan
  - push
  - dockerize
  - deploy

check-version:
  stage: check
  tags:
    - k8s  # shell runner для скорости
  script:
    - mvn --version

build-job:
  stage: build
  tags:
    - k8s  # shell runner - быстрый Maven кэш
  script:
    - echo "Building the WAR file"
    - mvn package
    - ls -l target/*.war
  artifacts:
    paths:
      - target/
    exclude:
      - target/**/*.log
      - target/**/node_modules/
      - target/**/*.tmp
      - target/**/cache/
    expire_in: 1 week

sonarscan:
  stage: sonarscan
  tags:
    - k8s  # shell runner
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar" 
    SONAR_HOST_URL: ${SONAR_HOST_URL}
    SONAR_TOKEN: ${SONAR_TOKEN}
  image:
    name: sonarsource/sonar-scanner-cli:latest
  script:
   - docker run --rm -v $(pwd):/usr/src -e SONAR_HOST_URL -e SONAR_TOKEN sonarsource/sonar-scanner-cli -Dsonar.projectBaseDir=/usr/src -Dsonar.qualitygate.wait=true

push-to-nexus:
  stage: push
  tags:
    - k8s  # shell runner
  script:
    - mvn $M2_EXTRA_OPTIONS deploy

dockerize:
  stage: dockerize
  tags:
    - docker-runner  # Docker runner для Kaniko
  image:
    name: gcr.io/kaniko-project/executor:v1.23.0-debug
    entrypoint: [""]
  script:
    - echo "{\"auths\":{\"${CI_REGISTRY}\":{\"auth\":\"$(printf "%s:%s" "${CI_REGISTRY_USER}" "${CI_REGISTRY_PASSWORD}" | base64 | tr -d '\n')\"}}}" > /kaniko/.docker/config.json
    - /kaniko/executor --context "${CI_PROJECT_DIR}" --dockerfile "${CI_PROJECT_DIR}/Dockerfile" --destination "${CI_REGISTRY_USER}/${IMAGE_NAME}:${TAG}"

deploy-to-kubernetes:
  stage: deploy
  tags:
    - k8s  # Используем shell runner где установлен Helm
  dependencies:
    - dockerize
  before_script:
    - mkdir -p .kube
    - pwd
    - ls -lha
    - echo "$KUBECONFIG" > .kube/config
    - kubectl cluster-info  # Проверяем подключение к кластеру
    - helm version  # Проверяем что Helm доступен
  script:
    - |
      echo "Deploying Spring Petclinic with Helm..."
      echo "Vars: "
      echo CI REG IMAGE: ${CI_REGISTRY_IMAGE}
      echo CI IMAGE TAG ${TAG}
      echo ===================
      helm upgrade --install petclinic petclinic-chart/ \
        --set image.tag=${TAG} \
        --set image.repository=${CI_REGISTRY_IMAGE} \
        --atomic \
        --timeout 5m
    - echo "Deployment completed successfully!"

```

<img width="1919" height="987" alt="image" src="https://github.com/user-attachments/assets/16042675-eb61-474b-b220-d487a79181da" />

Картинка. Завершенный Pipeline.

<img width="1919" height="987" alt="image" src="https://github.com/user-attachments/assets/47caf003-9fe4-4b42-815b-a1afb1819d68" />

Картинка. Сайт Perclinic.

Примечание: Если не работает DNS в runner, то нужно отредактировать config map с настройками DNS 
```
kubectl edit configmap coredns -n kube-system
```
В секцию hosts добавить локальный DNS сервер и в forward доабвить его IP - 192.168.50.1:
```
        hosts {
           192.168.50.1 gateway
        }
        prometheus :9153
        forward . 192.168.50.1 8.8.8.8 8.8.4.4 {
           max_concurrent 1000
        }
```
Примерный блок:
```
      hosts /etc/coredns/NodeHosts {
         192.168.50.1 gateway.local.lab
          ttl 60
          reload 15s
          fallthrough
        }
        prometheus :9153
       forward . 192.168.50.1 {
           max_concurrent 1000
        }

```

### 11.9 Обновление values.yaml с вашим Docker Hub username

```bash
# Замените yourdockerhubuser на ваш username
sed -i 's/yourdockerhubuser/ВАSH_DOCKER_USERNAME/g' petclinic-chart/values.yaml
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
Установка на ВМ с gitlab
```bash
# Обновляем систему
sudo apt update
sudo apt upgrade -y
sudo apt install -y curl git jq
# Добавьте официальный репозиторий GitLab Runner:
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | 
# Установите GitLab Runner:
sudo apt-get install gitlab-runner
# Регистрация Runner
# процесс регистрации:
# Выбираем executor = shell
sudo gitlab-runner register
# Запускаем 
sudo gitlab-runner run
# Установка нужных владельцев для gitlab-runner
sudo usermod -aG docker gitlab-runner
sudo usermod -aG docker $USER
echo Проверка user gitlab-runner должен быть в группе docker
sudo getent group docker

```
Установка maven:
```
sudo apt install -y maven
mvn --version
```
Альтернатив в k8s

GitLab Runner будет исполнять CI/CD задачи внутри Kubernetes кластера.

### 12.1 Добавление Helm репозитория GitLab

На K3s Master:
```bash
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20
```
```bash
helm repo add gitlab https://charts.gitlab.io
helm repo update

# Проверка
helm search repo gitlab-runner
```

### 12.2 Получение Registration Token

В GitLab создаем 2 runner, первый будет исполнятся в shell, дадим ему имя "shell-executor".
А второй runner будет запускаться в docker контейнере, дадим ему "docker-executor":

shell executor:
1. Admin Area (гаечный ключ) → CI/CD → Runners → Create instance runner → shell-executor
2. Скопируйте Registration token (под "Set up a shared runner manually")

```
# для shell executor
gitlab-runner register  --url http://gitlab.local.lab  --token glrt-Tm6E17vlALZ3MLUxvPusiG86MQp0OjEKdToxCw.01.121v8wq0a
```
docker executor:
1. Admin Area (гаечный ключ) → CI/CD → Runners → Create instance runner → docker-executor
2. Скопируйте Registration token (под "Set up a shared runner manually")
```
# для docker executor
gitlab-runner register  --url http://gitlab.local.lab  --token glrt-Tm6E17vlALZ3MLUxvPusiG86MQp0OjEKdToxCw.01.12124334
```
Пример токена: `GR1348941a1b2c3d4e5f6g7h8i9j0`
```
# Перезапускаем runner
sudo gitlab-runner restart
sudo gitlab-runner verify
# Ручной зарпуск
sudo gitlab-runner run
```
Примечание: Создаем runner и указываем имя shell-executor и docker-executor, по этому имени runner привязывается в проекту petclinic.



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

Или запушьте локально:

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
curl -I http://192.168.50.102:8081
```

#### Проблема: SonarQube scan fails

```bash
# Проверка доступности SonarQube
curl http://192.168.50.101:9000/api/system/status

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
# SonarQube
kubectl get pods -n sonarqube
kubectl logs -n sonarqube -l app=sonarqube --tail=100
kubectl describe pod -n sonarqube <pod-name>

# Nexus
kubectl get pods -n nexus
kubectl logs -n nexus -l app=nexus-repository-manager --tail=100

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
kubectl describe svc -n nexus nexus-nexus-repository-manager
```

#### Persistent Volumes

```bash
# PV и PVC
kubectl get pv
kubectl get pvc --all-namespaces

# Детали
kubectl describe pvc -n sonarqube
kubectl describe pvc -n nexus
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
sudo tcpdump -i ens18 port 80 -n

# iptables rules
sudo iptables -L -v -n
sudo iptables -t nat -L -v -n
```

#### Проверка связности

```bash
# С Gateway
ping -c 3 192.168.50.10  # GitLab
ping -c 3 192.168.50.20  # K3s Master
ping -c 3 192.168.50.101  # SonarQube
ping -c 3 192.168.50.102  # Nexus

# DNS resolution
nslookup gitlab.local.lab
nslookup sonarqube.local.lab

# HTTP проверка
curl -I http://gitlab.local.lab
curl -I http://nexus.local.lab
curl -I http://sonarqube.local.lab
```

### 14.4 Логи и Debugging

#### Централизованный сбор логов (опционально)

Установка EFK Stack (Elasticsearch, Fluentd, Kibana):

```bash
# На K3s Master
helm repo add elastic https://helm.elastic.co
helm repo update

# Elasticsearch
kubectl create namespace logging

helm install elasticsearch elastic/elasticsearch \
  --namespace logging \
  --set replicas=1 \
  --set minimumMasterNodes=1

# Kibana
helm install kibana elastic/kibana \
  --namespace logging \
  --set service.type=LoadBalancer

# Fluentd (для сбора логов)
kubectl apply -f https://raw.githubusercontent.com/fluent/fluentd-kubernetes-daemonset/master/fluentd-daemonset-elasticsearch.yaml
```

#### Простой debugging workflow

1. **Определите проблему**:
   ```bash
   kubectl get pods --all-namespaces | grep -v Running
   ```

2. **Проверьте events**:
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. **Просмотр логов**:
   ```bash
   kubectl logs <pod-name> -n <namespace> --previous  # Предыдущий crashed container
   kubectl logs <pod-name> -n <namespace> -f  # Follow current logs
   ```

4. **Exec в контейнер**:
   ```bash
   kubectl exec -it <pod-name> -n <namespace> -- /bin/bash
   # или
   kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
   ```

5. **Проверка ресурсов**:
   ```bash
   kubectl describe node <node-name>
   kubectl top pod -n <namespace>
   ```

### 14.5 Алерты и уведомления

#### Настройка GitLab Email Notifications

На GitLab VM:

```bash
sudo vim /etc/gitlab/gitlab.rb
```

Добавьте (для Gmail example):

```ruby
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.gmail.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "your-email@gmail.com"
gitlab_rails['smtp_password'] = "your-app-password"
gitlab_rails['smtp_domain'] = "smtp.gmail.com"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['smtp_tls'] = false
gitlab_rails['smtp_openssl_verify_mode'] = 'peer'

gitlab_rails['gitlab_email_from'] = 'your-email@gmail.com'
gitlab_rails['gitlab_email_reply_to'] = 'noreply@local.lab'
```

```bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart

# Тест email
sudo gitlab-rails console
# В консоли:
Notify.test_email('your-email@example.com', 'Test', 'Test body').deliver_now
```

#### Настройка GitLab Integrations

В GitLab:

1. Settings → Integrations
2. Выберите: Slack, Microsoft Teams, или Webhook
3. Настройте URLs и события:
   - Pipeline events
   - Job events
   - Deployment events

---

## Часть 15: Дополнительные настройки

### 15.1 SSL/TLS с Let's Encrypt

#### Установка Cert-Manager

```bash
# На K3s Master
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml

# Проверка
kubectl get pods -n cert-manager -w
```

#### Создание ClusterIssuer

```bash
cat > letsencrypt-issuer.yaml <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

kubectl apply -f letsencrypt-issuer.yaml
```

#### Установка Nginx Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.loadBalancerIP=192.168.50.104
```

#### Создание Ingress с SSL

```bash
cat > petclinic-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: petclinic-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - petclinic.local.lab
    secretName: petclinic-tls
  rules:
  - host: petclinic.local.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: petclinic
            port:
              number: 80
EOF

kubectl apply -f petclinic-ingress.yaml
```

**Важно**: Let's Encrypt требует публичный домен. Для локального lab используйте self-signed сертификаты.

### 15.2 Автоматическое масштабирование (HPA)

#### Установка Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Для K3s нужен patch (небезопасно для production!)
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'

# Проверка
kubectl top nodes
kubectl top pods -n default
```

#### Создание HPA для PetClinic

```bash
cat > petclinic-hpa.yaml <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: petclinic-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: petclinic
  minReplicas: 2
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max
EOF

kubectl apply -f petclinic-hpa.yaml

# Проверка
kubectl get hpa
kubectl describe hpa petclinic-hpa
```

#### Тест HPA с нагрузкой

```bash
# Генерация нагрузки
kubectl run -it --rm load-generator --image=busybox --restart=Never -- /bin/sh -c \
  "while true; do wget -q -O- http://petclinic.local.lab; done"

# В другом терминале наблюдение
kubectl get hpa petclinic-hpa -w
kubectl get pods -l app=petclinic -w
```

### 15.3 Мониторинг с Prometheus и Grafana

#### Установка kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword=admin \
  --set prometheus.service.type=LoadBalancer \
  --set prometheus.service.loadBalancerIP=192.168.50.105 \
  --set grafana.service.type=LoadBalancer \
  --set grafana.service.loadBalancerIP=192.168.50.106

# Проверка
kubectl get pods -n monitoring
kubectl get svc -n monitoring
```

#### Доступ к Grafana

1. URL: `http://192.168.50.106` (или настройте HAProxy)
2. Login: `admin` / Password: `admin`
3. Dashboards → Manage → Kubernetes
4. Импортируйте dashboard:
   - ID: `8588` (Kubernetes Deployment Statefulset Daemonset metrics)
   - ID: `6417` (Kubernetes Cluster Monitoring)
   - ID: `13770` (Kubernetes Monitoring)

#### Добавление в BIND и HAProxy

На Gateway:

```bash
# BIND
sudo vim /etc/bind/zones/db.local.lab
```

Добавьте:

```
prometheus      IN      A       192.168.50.105
grafana         IN      A       192.168.50.106
```

```bash
sudo systemctl restart bind9
```

HAProxy:

```bash
sudo vim /etc/haproxy/haproxy.cfg
```

Добавьте frontend ACL и backend:

```
    acl is_prometheus hdr(host) -i prometheus.local.lab
    acl is_grafana hdr(host) -i grafana.local.lab
    use_backend prometheus_back if is_prometheus
    use_backend grafana_back if is_grafana

backend prometheus_back
    mode http
    server prometheus 192.168.50.105:9090 check

backend grafana_back
    mode http
    server grafana 192.168.50.106:80 check
```

```bash
sudo systemctl restart haproxy
```

### 15.4 Backup и Disaster Recovery

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
    
    for kind in deployment statefulset service configmap secret pvc; do
        kubectl get $kind -n $ns -o yaml > "$BACKUP_PATH/$ns/${kind}.yaml" 2>/dev/null
    done
done

# Backup ETCD (K3s specific)
sudo cp -r /var/lib/rancher/k3s/server/db "$BACKUP_PATH/etcd-db"

# Compress backup
cd "$BACKUP_DIR"
tar -czf "k8s-backup-$DATE.tar.gz" "k8s-backup-$DATE"
rm -rf "k8s-backup-$DATE"

# Keep only last 7 days
find "$BACKUP_DIR" -name "k8s-backup-*.tar.gz" -mtime +7 -delete

echo "Backup completed: k8s-backup-$DATE.tar.gz"
```

```bash
sudo chmod +x /usr/local/bin/k8s-backup.sh

# Тест
sudo /usr/local/bin/k8s-backup.sh
```

#### Cron для автоматических backup

```bash
sudo crontab -e
```

Добавьте:

```
# Kubernetes backup каждый день в 2:00 AM
0 2 * * * /usr/local/bin/k8s-backup.sh >> /var/log/k8s-backup.log 2>&1
```

#### GitLab Backup

На GitLab VM:

```bash
# Создание backup
sudo gitlab-backup create

# Backup хранятся в
ls -lh /var/opt/gitlab/backups/

# Автоматический backup через cron
sudo crontab -e
```

Добавьте:

```
# GitLab backup каждый день в 1:00 AM
0 1 * * * /opt/gitlab/bin/gitlab-backup create CRON=1
```

#### Restore процедура

**Kubernetes restore**:

```bash
# Распаковка backup
cd /home/ubuntu/backups
tar -xzf k8s-backup-YYYYMMDD_HHMMSS.tar.gz
cd k8s-backup-YYYYMMDD_HHMMSS

# Restore namespace
kubectl apply -f <namespace>/
```

**GitLab restore**:

```bash
# Остановка процессов
sudo gitlab-ctl stop puma
sudo gitlab-ctl stop sidekiq

# Restore
sudo gitlab-backup restore BACKUP=<timestamp>

# Restart
sudo gitlab-ctl restart
sudo gitlab-rake gitlab:check SANITIZE=true
```

### 15.5 Security Hardening

#### Network Policies

```bash
cat > network-policy.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: petclinic-netpol
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: petclinic
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53  # DNS
  - to:
    - podSelector: {}
EOF

kubectl apply -f network-policy.yaml
```

#### Pod Security Standards

```bash
kubectl label namespace default pod-security.kubernetes.io/enforce=baseline
kubectl label namespace default pod-security.kubernetes.io/audit=restricted
kubectl label namespace default pod-security.kubernetes.io/warn=restricted
```

#### Secrets Management

Использование External Secrets Operator (опционально):

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace
```

---

## Заключение

### Что мы построили

Вы успешно развернули полноценную enterprise-grade DevOps платформу на базе Proxmox VE:

✅ **Инфраструктура**:
- 5 виртуальных машин с оптимальным распределением ресурсов
- Двухуровневая сетевая архитектура с полной изоляцией
- NAT Gateway с iptables для безопасного доступа
- DNS сервер BIND9 для локального резолвинга
- HAProxy для централизованного доступа к сервисам

✅ **CI/CD Pipeline**:
- GitLab CE для управления кодом и оркестрации CI/CD
- 6-stage pipeline: build → test → quality → package → dockerize → deploy
- Автоматические тесты с покрытием кода
- Статический анализ кода с SonarQube
- Хранение артефактов в Nexus Repository
- Контейнеризация с Docker/Kaniko
- Автоматический deployment в Kubernetes

✅ **Kubernetes Кластер**:
- K3s (3 ноды: 1 master + 2 workers)
- MetalLB LoadBalancer для bare-metal
- Helm для управления приложениями
- GitLab Runner в Kubernetes для CI/CD
- Готовность к production workloads

✅ **Дополнительные возможности**:
- Мониторинг с Prometheus и Grafana
- Автоматическое масштабирование (HPA)
- Backup и disaster recovery
- Security hardening с Network Policies

### Архитектурные преимущества

🔒 **Безопасность**:
- Изоляция DevOps сервисов во внутренней сети
- Единая точка входа через Jump Host
- Контроль трафика с iptables
- Pod Security Standards в Kubernetes

⚡ **Производительность**:
- Распределение нагрузки между worker нодами
- Кэширование Maven зависимостей
- Оптимизация ресурсов для каждого компонента
- LoadBalancer с MetalLB

🔄 **Автоматизация**:
- End-to-end pipeline от commit до production
- Автоматические тесты и анализ качества
- Zero-downtime deployments
- Rollback capabilities

📈 **Масштабируемость**:
- Горизонтальное масштабирование с HPA
- Легкое добавление worker нод
- Модульная архитектура
- Cloud-ready (легко мигрировать в облако)

### Метрики успеха

- **Время от коммита до production**: ~15-20 минут
- **Покрытие тестами**: отслеживается в SonarQube
- **Качество кода**: автоматический контроль через Quality Gates
- **Uptime**: высокая доступность через репликацию pods
- **Recovery Time**: < 5 минут с автоматическими backup

### Дальнейшее развитие

#### Краткосрочные улучшения (1-2 недели)

1. **Мониторинг и Observability**:
   ```bash
   # Интеграция Application Performance Monitoring
   - Добавление Jaeger для distributed tracing
   - Настройка алертов в AlertManager
   - Кастомные Grafana dashboards для PetClinic
   - Логирование с ELK/EFK Stack
   ```

2. **Security Enhancements**:
   ```bash
   # Улучшение безопасности
   - Настройка OAuth2/OIDC для GitLab
   - Интеграция Vault для secrets management
   - Сканирование Docker образов (Trivy, Clair)
   - Regular security audits с Kube-bench
   ```

3. **Advanced CI/CD**:
   ```bash
   # Расширение pipeline
   - Integration testing с Selenium/Cypress
   - Performance testing с JMeter/Gatling
   - Security scanning с OWASP ZAP
   - Automated release notes generation
   ```

#### Среднесрочные улучшения (1-3 месяца)

4. **Multi-Environment Strategy**:
   ```yaml
   # Создание окружений
   environments:
     - development:   namespace: dev
     - staging:       namespace: staging
     - production:    namespace: prod
   
   # Blue-Green Deployment
   - Duplicate production environment
   - Switch traffic with Ingress
   - Zero-downtime deployments
   
   # Canary Deployments
   - Использование Flagger
   - Постепенный rollout новых версий
   - Automatic rollback на ошибках
   ```

5. **GitOps подход**:
   ```bash
   # Внедрение ArgoCD
   helm repo add argo https://argoproj.github.io/argo-helm
   helm install argocd argo/argo-cd -n argocd --create-namespace
   
   # Декларативное управление через Git
   - Infrastructure as Code
   - Application definitions в Git
   - Automatic sync и self-healing
   ```

6. **Service Mesh**:
   ```bash
   # Istio или Linkerd для advanced networking
   - Mutual TLS между сервисами
   - Traffic management
   - Observability из коробки
   - Circuit breaking и retries
   ```

#### Долгосрочные улучшения (3-6 месяцев)

7. **Микросервисная архитектура**:
   - Разделение PetClinic на микросервисы
   - API Gateway (Kong, Ambassador)
   - Service discovery
   - Distributed configuration

8. **Cloud Migration Strategy**:
   ```bash
   # Hybrid cloud readiness
   - Тестирование на AWS EKS / GCP GKE
   - Multi-cloud deployments
   - Cloud cost optimization
   - Disaster recovery в облаке
   ```

9. **AI/ML Integration**:
   - Kubeflow для ML pipelines
   - Model serving с Seldon/KServe
   - MLOps practices

### Рекомендации по эксплуатации

#### Ежедневные задачи

```bash
# Morning checks
kubectl get nodes
kubectl get pods --all-namespaces | grep -v Running
kubectl top nodes
df -h  # На всех нодах

# GitLab health
curl -I http://gitlab.local.lab
sudo gitlab-ctl status  # На GitLab VM

# Pipeline monitoring
# Проверка failed pipelines в GitLab UI
```

#### Еженедельные задачи

```bash
# Security updates
sudo apt update && sudo apt upgrade -y  # На всех VM

# Backup verification
ls -lh /home/ubuntu/backups/
# Тестовый restore одного namespace

# Certificate expiry check
kubectl get certificates --all-namespaces

# Resource usage review
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=memory
```

#### Ежемесячные задачи

```bash
# Full backup test
# Выполните полный restore в test environment

# Security audit
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'

# Performance review
# Анализ Grafana метрик за месяц
# Оптимизация ресурсных лимитов

# Documentation update
# Обновление runbooks и procedures
```

#### Ежеквартальные задачи

```bash
# Disaster recovery drill
# Полное восстановление системы с нуля

# Capacity planning
# Оценка роста и планирование расширения

# Technology updates
# Обновление major versions (K3s, GitLab, и т.д.)

# Cost analysis
# Анализ использования ресурсов и ROI
```

### Troubleshooting Guide

#### Проблема: GitLab недоступен

```bash
# 1. Проверка VM
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10
sudo gitlab-ctl status

# 2. Проверка сервисов
sudo gitlab-ctl restart puma
sudo gitlab-ctl tail puma

# 3. Проверка ресурсов
free -h
df -h

# 4. Проверка HAProxy
ssh ubuntu@10.0.10.30
curl http://192.168.50.10  # Прямой доступ
sudo systemctl status haproxy
```

#### Проблема: Pipeline зависает

```bash
# 1. Проверка GitLab Runner
kubectl get pods -n gitlab-runner
kubectl logs -n gitlab-runner -l app=gitlab-runner-gitlab-runner

# 2. Проверка runner registration
# В GitLab: Admin → CI/CD → Runners

# 3. Проверка ресурсов K8s
kubectl top nodes
kubectl describe node <node-with-runner-pod>

# 4. Restart runner
kubectl rollout restart deployment -n gitlab-runner
```

#### Проблема: Kubernetes pod в CrashLoopBackOff

```bash
# 1. Посмотреть что случилось
kubectl describe pod <pod-name>

# 2. Логи текущего и предыдущего контейнера
kubectl logs <pod-name>
kubectl logs <pod-name> --previous

# 3. Проверка events
kubectl get events --sort-by='.lastTimestamp' | grep <pod-name>

# 4. Проверка ресурсов
kubectl top pod <pod-name>

# 5. Debug pod
kubectl debug <pod-name> -it --image=busybox
```

#### Проблема: Service недоступен через LoadBalancer

```bash
# 1. Проверка service
kubectl get svc <service-name>
kubectl describe svc <service-name>

# 2. Проверка MetalLB
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l app=metallb

# 3. Проверка IP pool
kubectl get ipaddresspool -n metallb-system

# 4. Тест прямого доступа
curl http://<loadbalancer-ip>:<port>

# 5. Проверка endpoints
kubectl get endpoints <service-name>
```

#### Проблема: DNS не резолвится

```bash
# 1. На Gateway проверка BIND
sudo systemctl status bind9
sudo named-checkzone local.lab /etc/bind/zones/db.local.lab

# 2. Тест DNS
dig @192.168.50.1 gitlab.local.lab
nslookup gitlab.local.lab 192.168.50.1

# 3. Логи BIND
sudo journalctl -u bind9 -f

# 4. На клиенте проверка настроек
# Windows: ipconfig /all
# Linux: cat /etc/resolv.conf
```

### Полезные команды

#### Kubernetes

```bash
# Быстрая диагностика
kubectl get all --all-namespaces
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -20

# Ресурсы
kubectl top nodes
kubectl top pods --all-namespaces --sort-by=cpu
kubectl describe node <node-name> | grep -A 5 "Allocated resources"

# Логи
kubectl logs -f <pod-name>
kubectl logs -f <pod-name> -c <container-name>
kubectl logs --previous <pod-name>  # Crashed container

# Debug
kubectl exec -it <pod-name> -- /bin/bash
kubectl port-forward <pod-name> 8080:8080
kubectl debug node/<node-name> -it --image=ubuntu

# Cleanup
kubectl delete pod <pod-name> --grace-period=0 --force
kubectl delete namespace <namespace> --grace-period=0 --force
```

#### GitLab

```bash
# Status
sudo gitlab-ctl status
sudo gitlab-ctl service-list

# Logs
sudo gitlab-ctl tail
sudo gitlab-ctl tail nginx
sudo gitlab-ctl tail puma

# Restart
sudo gitlab-ctl restart
sudo gitlab-ctl restart puma
sudo gitlab-ctl hup nginx

# Console
sudo gitlab-rails console
# В консоли:
# User.find_by(username: 'root')
# Project.find_by(name: 'spring-petclinic')

# Check
sudo gitlab-rake gitlab:check SANITIZE=true
sudo gitlab-rake gitlab:doctor:secrets
```

#### Docker Registry

```bash
# Список образов в Nexus/Registry
curl -u admin:password http://nexus.local.lab/v2/_catalog

# Теги образа
curl -u admin:password http://nexus.local.lab/v2/spring-petclinic/tags/list

# Docker Hub
docker search <username>/spring-petclinic
docker pull <username>/spring-petclinic:latest
```

### Финальный чек-лист

Перед завершением убедитесь:

- [ ] Все VM доступны и работают
- [ ] DNS резолвит все сервисы (gitlab, nexus, sonarqube, petclinic)
- [ ] HAProxy проксирует трафик корректно
- [ ] GitLab доступен и работает
- [ ] Kubernetes кластер в статусе Ready (все ноды)
- [ ] MetalLB назначает IP адреса
- [ ] SonarQube доступен и работает
- [ ] Nexus доступен и работает
- [ ] GitLab Runner зарегистрирован и активен
- [ ] Тестовый pipeline успешно выполнился
- [ ] PetClinic задеплоен и доступен
- [ ] Мониторинг настроен (если установлен)
- [ ] Backup скрипты созданы и протестированы
- [ ] Документация обновлена

### Полезные ресурсы

#### Официальная документация

- **Proxmox**: https://pve.proxmox.com/wiki/Main_Page
- **Terraform Proxmox Provider**: https://registry.terraform.io/providers/Telmate/proxmox/latest/docs
- **GitLab**: https://docs.gitlab.com/
- **K3s**: https://docs.k3s.io/
- **Kubernetes**: https://kubernetes.io/docs/
- **Helm**: https://helm.sh/docs/
- **SonarQube**: https://docs.sonarqube.org/
- **Nexus**: https://help.sonatype.com/repomanager3
- **HAProxy**: http://www.haproxy.org/
- **BIND9**: https://bind9.readthedocs.io/

#### Community и поддержка

- **Proxmox Forum**: https://forum.proxmox.com/
- **GitLab Community**: https://forum.gitlab.com/
- **Kubernetes Slack**: https://kubernetes.slack.com/
- **Stack Overflow**: теги kubernetes, gitlab-ci, k3s

#### Книги и курсы

- "Kubernetes Up & Running" by Kelsey Hightower
- "GitLab CI/CD Pipeline" courses on Udemy
- "Site Reliability Engineering" by Google
- "The DevOps Handbook" by Gene Kim

### Контакты и поддержка

Если возникнут проблемы:

1. **Проверьте логи** - 80% проблем видны в логах
2. **Используйте поиск** - большинство проблем уже решены
3. **Community форумы** - активное сообщество всегда поможет
4. **GitHub Issues** - для специфических багов в проектах

### Благодарности

Эта инструкция стала возможной благодаря:

- Open Source сообществу
- Документации всех использованных проектов
- DevOps практикам и паттернам индустрии
- Вашему желанию учиться и строить!

---

## Приложения

### Приложение A: Шпаргалка по командам

```bash
# === Proxmox ===
qm list                          # Список VM
qm status <vmid>                 # Статус VM
qm start <vmid>                  # Старт VM
qm shutdown <vmid>               # Shutdown VM
pvesm status                     # Storage status

# === Terraform ===
terraform init                   # Инициализация
terraform plan                   # План изменений
terraform apply                  # Применение
terraform destroy                # Удаление
terraform output                 # Вывод outputs

# === SSH/Jump Host ===
ssh ubuntu@10.0.10.30                               # Gateway
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.10      # GitLab через jump
ssh -J ubuntu@10.0.10.30 ubuntu@192.168.50.20      # K3s Master через jump

# === Git ===
git clone <url>                  # Клонирование
git add .                        # Добавить все
git commit -m "msg"              # Коммит
git push origin master           # Push
git pull                         # Pull

# === GitLab ===
sudo gitlab-ctl status           # Статус
sudo gitlab-ctl restart          # Restart
sudo gitlab-ctl tail             # Логи
sudo gitlab-rake gitlab:check    # Health check

# === Kubernetes ===
kubectl get nodes                # Ноды
kubectl get pods -A              # Все pods
kubectl get svc -A               # Все services
kubectl describe pod <name>      # Детали pod
kubectl logs -f <pod>            # Логи
kubectl exec -it <pod> -- bash   # Exec в pod
kubectl top nodes                # Ресурсы nodes
kubectl top pods -A              # Ресурсы pods

# === Helm ===
helm list -A                     # Все releases
helm install <name> <chart>      # Установка
helm upgrade <name> <chart>      # Обновление
helm uninstall <name>            # Удаление
helm rollback <name> 0           # Откат

# === Docker ===
docker ps                        # Running containers
docker images                    # Images
docker pull <image>              # Pull image
docker build -t <tag> .          # Build image
docker push <image>              # Push image

# === DNS ===
dig @192.168.50.1 gitlab.local.lab          # DNS query
nslookup gitlab.local.lab                    # DNS lookup
host gitlab.local.lab                        # Host lookup

# === Network ===
ping <host>                      # Ping
curl <url>                       # HTTP request
curl -I <url>                    # HTTP headers
netstat -tulpn                   # Open ports
ss -tulpn                        # Socket statistics
```

### Приложение B: Переменные окружения GitLab CI/CD

Полный список переменных для копирования в GitLab:

```yaml
# Nexus
NEXUS_USER: gitlab-ci
NEXUS_PASSWORD: <пароль>
NEXUS_URL: http://192.168.50.102:8081

# SonarQube
SONAR_HOST_URL: http://192.168.50.101:9000
SONAR_TOKEN: squ_<токен>

# Docker Hub
CI_REGISTRY: https://index.docker.io/v1/
CI_REGISTRY_USER: <username>
CI_REGISTRY_PASSWORD: <token>

# Kubernetes
KUBECONFIG: <содержимое ~/.kube/config с master> (тип: File)
```

### Приложение C: Сетевая карта

```
┌─────────────────────────────────────────────────────────────┐
│                       Internet (Grey IP)                     │
└────────────────────────┬────────────────────────────────────┘
                         │
                    ┌────┴────┐
                    │ Router  │
                    │10.0.10.1│
                    └────┬────┘
                         │
              ┌──────────┴──────────┐
              │   Proxmox Host      │
              │   10.0.10.200       │
              └──────────┬──────────┘
                         │
         ┌───────────────┴───────────────┐
         │                               │
    ┌────┴────┐ vmbr0            vmbr1 ┌┴────────┐
    │ External│ 10.0.10.0/24           │ Internal│
    │ Network │                        │ Network │
    └────┬────┘                        └┬────────┘
         │                               │
    ┌────┴──────────┐         ┌─────────┴──────────────────┐
    │   Gateway VM  │         │    Internal Services       │
    │ 10.0.10.30 ←──┼─────────┼→ 192.168.50.1 (Gateway)   │
    │ (External)    │         │   192.168.50.10 (GitLab)   │
    │               │         │   192.168.50.20 (K3s Mstr) │
    │ Services:     │         │   192.168.50.21 (K3s Wkr1) │
    │ - NAT/iptables│         │   192.168.50.22 (K3s Wkr2) │
    │ - BIND9 DNS   │         │   192.168.50.101 (SonarQ)  │
    │ - HAProxy     │         │   192.168.50.102 (Nexus)   │
    │ - Jump Host   │         │   192.168.50.103 (PetClin) │
    └───────────────┘         └────────────────────────────┘

Access from Windows:
1. DNS: 10.0.10.30
2. SSH Jump: ubuntu@10.0.10.30
3. Web Services: http://*.local.lab (через HAProxy)
```

### Приложение D: Порты и протоколы

| Сервис | Порт | Протокол | Доступ |
|--------|------|----------|--------|
| SSH Gateway | 22 | TCP | 10.0.10.30:22 |
| HTTP (HAProxy) | 80 | TCP | 10.0.10.30:80 |
| HTTPS (HAProxy) | 443 | TCP | 10.0.10.30:443 |
| DNS (BIND9) | 53 | UDP/TCP | 192.168.50.1:53 |
| HAProxy Stats | 8404 | TCP | 10.0.10.30:8404 |
| GitLab HTTP | 80 | TCP | 192.168.50.10:80 |
| GitLab SSH | 22 | TCP | 192.168.50.10:22 |
| K3s API | 6443 | TCP | 192.168.50.20:6443 |
| SonarQube | 9000 | TCP | 192.168.50.101:9000 |
| Nexus | 8081 | TCP | 192.168.50.102:8081 |
| PetClinic | 80 | TCP | 192.168.50.103:80 |
| Prometheus | 9090 | TCP | 192.168.50.105:9090 |
| Grafana | 80 | TCP | 192.168.50.106:80 |

---

## Финальные слова

Построена полнофункциональная DevOps платформа enterprise-уровняна собственном оборудовании. Эта инфраструктура:

✅ Полностью автоматизирована от кода до production  
✅ Следует современным best practices  
✅ Масштабируема и расширяема  
✅ Безопасна с изоляцией сетей  
✅ Production-ready для реальных проектов  

**Ключевые достижения:**

- Развернута multi-VM инфраструктура с Terraform
- Настроена полная сетевая изоляция с NAT и DNS
- Построен CI/CD pipeline с автоматическими тестами и quality gates
- Развернут Kubernetes кластер для контейнерных приложений
- Интегрированы industry-standard инструменты (GitLab, SonarQube, Nexus)
- Настроен мониторинг и backup

**Используемый стек:**

- Infrastructure as Code (Terraform)
- Сетевые технологии (NAT, DNS, reverse proxy)
- CI/CD pipeline design и реализация
- Kubernetes администрирование
- Container orchestration с Helm
- DevOps best practices

**Что нужно делать далее:**

1. Изучить метрики и логи системы
2. Экспериментировать с различными приложениями
3. Расширять функциональность постепенно
4. Документировать все изменения
5. Делится опытом с сообществом

---


