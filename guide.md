# Production-Ready DevOps Infrastructure Guide

## Архитектура и Топология

```
Internet
    │
    ├─→ Router (10.0.10.1)
    │
    └─→ Infrastructure Hosts
            │
            ├─→ Management VLAN (10.0.10.0/24)
            │   └─→ Bastion/Jump Host: 10.0.10.30
            │
            ├─→ Infrastructure VLAN (192.168.10.0/24)
            │   ├─→ GitLab Primary: 192.168.10.10
            │   ├─→ GitLab Secondary (HA): 192.168.10.11
            │   ├─→ Nexus: 192.168.10.20
            │   ├─→ SonarQube: 192.168.10.30
            │   ├─→ PostgreSQL (shared): 192.168.10.40
            │   └─→ NFS/Ceph Storage: 192.168.10.50-52
            │
            ├─→ Kubernetes VLAN (192.168.20.0/24)
            │   ├─→ K3s Master-1: 192.168.20.10
            │   ├─→ K3s Master-2: 192.168.20.11 (HA)
            │   ├─→ K3s Master-3: 192.168.20.12 (HA)
            │   ├─→ K3s Worker-1: 192.168.20.21
            │   ├─→ K3s Worker-2: 192.168.20.22
            │   ├─→ K3s Worker-3: 192.168.20.23
            │   └─→ MetalLB Pool: 192.168.20.100-150
            │
            └─→ DMZ VLAN (192.168.30.0/24)
                ├─→ HAProxy-1: 192.168.30.10 (VRRP Master)
                ├─→ HAProxy-2: 192.168.30.11 (VRRP Backup)
                └─→ VIP: 192.168.30.1 (Keepalived)
```
### Требования к ресурсам (Production)
| VM | CPU | RAM | Disk | Назначение |
|----|-----|-----|------|-----------|
| **Bastion** | 2 | 2GB | 20GB | SSH Jump, Monitoring Agent |
| **GitLab** | 4 | 16GB | 100GB | Git, CI/CD, Container Registry |
| **Nexus** | 4 | 8GB | 200GB | Artifact Repository |
| **SonarQube** | 4 | 8GB | 50GB | Code Quality |
| **PostgreSQL** | 4 | 8GB | 100GB | Shared DB (GitLab, Sonar) |
| **HAProxy-1** | 2 | 4GB | 30GB | Load Balancer (Master) |
| **HAProxy-2** | 2 | 4GB | 30GB | Load Balancer (Backup) |
| **K3s Master-1** | 4 | 8GB | 50GB | Control Plane |
| **K3s Master-2** | 4 | 8GB | 50GB | Control Plane |
| **K3s Master-3** | 4 | 8GB | 50GB | Control Plane |
| **K3s Worker-1** | 4 | 16GB | 100GB | Workloads |
| **K3s Worker-2** | 4 | 16GB | 100GB | Workloads |
| **K3s Worker-3** | 4 | 16GB | 100GB | Workloads |

**Итого:** 46 vCPU, 126GB RAM, 1TB Disk


## Этап 1: Подготовка Базовой Инфраструктуры

### 1.1 Настройка VLAN на хостах

```bash
# На каждом хосте создаем VLAN интерфейсы
# /etc/network/interfaces

auto eth0
iface eth0 inet manual

# Management VLAN
auto eth0.10
iface eth0.10 inet static
    address 10.0.10.X/24
    gateway 10.0.10.1
    vlan-raw-device eth0

# Infrastructure VLAN
auto eth0.192
iface eth0.192 inet static
    address 192.168.10.X/24
    vlan-raw-device eth0

# Kubernetes VLAN
auto eth0.20
iface eth0.20 inet static
    address 192.168.20.X/24
    vlan-raw-device eth0

# DMZ VLAN
auto eth0.30
iface eth0.30 inet static
    address 192.168.30.X/24
    vlan-raw-device eth0

# Перезапуск сети
systemctl restart networking
```

### 1.2 Создание NFS Storage для Shared Data

```bash
# На выделенном NFS сервере (192.168.10.50)
apt update && apt install nfs-kernel-server -y

# Создаем директории
mkdir -p /export/gitlab-data
mkdir -p /export/nexus-data
mkdir -p /export/sonarqube-data
mkdir -p /export/k8s-pv

# Настраиваем /etc/exports
cat << EOF >> /etc/exports
/export/gitlab-data 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/export/nexus-data 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/export/sonarqube-data 192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
/export/k8s-pv 192.168.20.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF

# Применяем изменения
exportfs -arv
systemctl enable --now nfs-server
```

## Этап 2: Развертывание Stateful Infrastructure Services

### 2.1 PostgreSQL High Availability Cluster

```bash
# VM: postgresql-primary (192.168.10.40)
# Specs: 4 vCPU, 8GB RAM, 100GB SSD

# Установка PostgreSQL 15
apt update && apt install -y postgresql-15 postgresql-contrib-15

# Настройка для HA /etc/postgresql/15/main/postgresql.conf
cat << EOF >> /etc/postgresql/15/main/postgresql.conf
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/15/archive/%f && cp %p /var/lib/postgresql/15/archive/%f'
EOF

# Настройка pg_hba.conf
cat << EOF >> /etc/postgresql/15/main/pg_hba.conf
host    replication     replicator      192.168.10.0/24         scram-sha-256
host    all             all             192.168.10.0/24         scram-sha-256
host    all             all             192.168.20.0/24         scram-sha-256
EOF

# Создаем пользователя для репликации
sudo -u postgres psql << EOF
CREATE USER replicator WITH REPLICATION ENCRYPTED PASSWORD 'strong_password';
CREATE DATABASE gitlab_production;
CREATE DATABASE sonarqube;
CREATE USER gitlab WITH ENCRYPTED PASSWORD 'gitlab_pass';
CREATE USER sonarqube WITH ENCRYPTED PASSWORD 'sonar_pass';
GRANT ALL PRIVILEGES ON DATABASE gitlab_production TO gitlab;
GRANT ALL PRIVILEGES ON DATABASE sonarqube TO sonarqube;
EOF

systemctl restart postgresql
```

### 2.2 GitLab Installation (Primary)

```bash
# VM: gitlab-primary (192.168.10.10)
# Specs: 8 vCPU, 16GB RAM, 200GB SSD

# Монтируем NFS для данных
apt install -y nfs-common
mkdir -p /var/opt/gitlab
echo "192.168.10.50:/export/gitlab-data /var/opt/gitlab nfs defaults 0 0" >> /etc/fstab
mount -a

# Установка GitLab
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ee/script.deb.sh | bash
EXTERNAL_URL="https://gitlab.yourdomain.com" apt-get install -y gitlab-ee

# Настройка /etc/gitlab/gitlab.rb
cat << 'EOF' > /etc/gitlab/gitlab.rb
external_url 'https://gitlab.yourdomain.com'

# PostgreSQL external
postgresql['enable'] = false
gitlab_rails['db_adapter'] = 'postgresql'
gitlab_rails['db_encoding'] = 'unicode'
gitlab_rails['db_host'] = '192.168.10.40'
gitlab_rails['db_port'] = 5432
gitlab_rails['db_database'] = 'gitlab_production'
gitlab_rails['db_username'] = 'gitlab'
gitlab_rails['db_password'] = 'gitlab_pass'

# Redis внутренний (или можно вынести)
redis['enable'] = true

# GitLab Runner integration
gitlab_rails['gitlab_shell_ssh_port'] = 22

# Backup settings
gitlab_rails['backup_path'] = "/var/opt/gitlab/backups"
gitlab_rails['backup_keep_time'] = 604800

# Email settings (опционально)
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.gmail.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "your-email@gmail.com"
gitlab_rails['smtp_password'] = "your-password"
gitlab_rails['smtp_domain'] = "smtp.gmail.com"
gitlab_rails['smtp_authentication'] = "login"
gitlab_rails['smtp_enable_starttls_auto'] = true
gitlab_rails['gitlab_email_from'] = 'gitlab@yourdomain.com'

# Monitoring
prometheus['enable'] = true
grafana['enable'] = true
EOF

# Применяем конфигурацию
gitlab-ctl reconfigure
gitlab-ctl restart

# Получаем initial root password
cat /etc/gitlab/initial_root_password
```

### 2.3 Nexus Repository Manager

```bash
# VM: nexus (192.168.10.20)
# Specs: 4 vCPU, 8GB RAM, 500GB SSD

# Монтируем NFS
apt install -y nfs-common
mkdir -p /opt/sonatype-work
echo "192.168.10.50:/export/nexus-data /opt/sonatype-work nfs defaults 0 0" >> /etc/fstab
mount -a

# Установка Java 11
apt update && apt install -y openjdk-11-jdk

# Загрузка Nexus
cd /opt
wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz
tar -xvf latest-unix.tar.gz
mv nexus-3.* nexus

# Создаем пользователя
useradd -r -m -U -d /opt/sonatype-work -s /bin/bash nexus
chown -R nexus:nexus /opt/nexus /opt/sonatype-work

# Systemd service
cat << 'EOF' > /etc/systemd/system/nexus.service
[Unit]
Description=Nexus Repository Manager
After=network.target

[Service]
Type=forking
LimitNOFILE=65536
ExecStart=/opt/nexus/bin/nexus start
ExecStop=/opt/nexus/bin/nexus stop
User=nexus
Restart=on-abort
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

# Настройка nexus.vmoptions для production
cat << EOF > /opt/nexus/bin/nexus.vmoptions
-Xms2703m
-Xmx2703m
-XX:MaxDirectMemorySize=2703m
-XX:+UnlockDiagnosticVMOptions
-XX:+LogVMOutput
-XX:LogFile=/opt/sonatype-work/nexus3/log/jvm.log
-XX:-OmitStackTraceInFastThrow
-Djava.net.preferIPv4Stack=true
-Dkaraf.home=.
-Dkaraf.base=.
-Dkaraf.etc=etc/karaf
-Djava.util.logging.config.file=etc/karaf/java.util.logging.properties
-Dkaraf.data=/opt/sonatype-work/nexus3
-Dkaraf.log=/opt/sonatype-work/nexus3/log
-Djava.io.tmpdir=/opt/sonatype-work/nexus3/tmp
EOF

systemctl daemon-reload
systemctl enable --now nexus

# Проверка
systemctl status nexus
# Nexus будет доступен на http://192.168.10.20:8081
# Initial admin password: cat /opt/sonatype-work/nexus3/admin.password
```

### 2.4 SonarQube Installation

```bash
# VM: sonarqube (192.168.10.30)
# Specs: 4 vCPU, 8GB RAM, 100GB SSD

# Монтируем NFS
apt install -y nfs-common
mkdir -p /opt/sonarqube-data
echo "192.168.10.50:/export/sonarqube-data /opt/sonarqube-data nfs defaults 0 0" >> /etc/fstab
mount -a

# System tuning для SonarQube
cat << EOF >> /etc/sysctl.conf
vm.max_map_count=524288
fs.file-max=131072
EOF
sysctl -p

cat << EOF >> /etc/security/limits.conf
sonarqube   -   nofile   131072
sonarqube   -   nproc    8192
EOF

# Установка Java 17
apt update && apt install -y openjdk-17-jdk unzip

# Загрузка SonarQube
cd /opt
wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-10.3.0.82913.zip
unzip sonarqube-10.3.0.82913.zip
mv sonarqube-10.3.0.82913 sonarqube

# Создаем пользователя
useradd -r -m -U -d /opt/sonarqube -s /bin/bash sonarqube
chown -R sonarqube:sonarqube /opt/sonarqube /opt/sonarqube-data

# Настройка /opt/sonarqube/conf/sonar.properties
cat << EOF > /opt/sonarqube/conf/sonar.properties
sonar.jdbc.username=sonarqube
sonar.jdbc.password=sonar_pass
sonar.jdbc.url=jdbc:postgresql://192.168.10.40/sonarqube
sonar.web.host=0.0.0.0
sonar.web.port=9000
sonar.path.data=/opt/sonarqube-data/data
sonar.path.temp=/opt/sonarqube-data/temp
EOF

# Systemd service
cat << 'EOF' > /etc/systemd/system/sonarqube.service
[Unit]
Description=SonarQube service
After=network.target network-online.target postgresql.service
Requires=network-online.target

[Service]
Type=forking
ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop
User=sonarqube
Group=sonarqube
Restart=on-failure
LimitNOFILE=131072
LimitNPROC=8192

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sonarqube

# Проверка
systemctl status sonarqube
# SonarQube доступен на http://192.168.10.30:9000
# Default credentials: admin/admin
```

## Этап 3: K3s Kubernetes Cluster Deployment

### 3.1 Подготовка всех K3s нод

```bash
# Выполнить на ВСЕХ нодах (masters + workers)

# Отключаем swap
swapoff -a
sed -i '/swap/d' /etc/fstab

# Настройка системы
cat << EOF > /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat << EOF > /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

# Установка зависимостей
apt update
apt install -y curl wget nfs-common open-iscsi
```

### 3.2 Установка первого Master Node

```bash
# На k3s-master-1 (192.168.20.10)

curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --tls-san=192.168.20.10 \
  --tls-san=192.168.20.1 \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode=644 \
  --node-ip=192.168.20.10 \
  --advertise-address=192.168.20.10 \
  --flannel-iface=eth0

# Сохраняем токен для других нод
cat /var/lib/rancher/k3s/server/node-token

# Проверка
kubectl get nodes
```

### 3.3 Добавление дополнительных Master нод (HA)

```bash
# На k3s-master-2 (192.168.20.11)
export K3S_TOKEN="<token-from-master-1>"

curl -sfL https://get.k3s.io | sh -s - server \
  --server https://192.168.20.10:6443 \
  --token=${K3S_TOKEN} \
  --tls-san=192.168.20.11 \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode=644 \
  --node-ip=192.168.20.11

# На k3s-master-3 (192.168.20.12)
curl -sfL https://get.k3s.io | sh -s - server \
  --server https://192.168.20.10:6443 \
  --token=${K3S_TOKEN} \
  --tls-san=192.168.20.12 \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode=644 \
  --node-ip=192.168.20.12
```

### 3.4 Добавление Worker нод

```bash
# На всех worker нодах (192.168.20.21-23)
export K3S_TOKEN="<token-from-master-1>"
export K3S_URL="https://192.168.20.10:6443"

curl -sfL https://get.k3s.io | sh -s - agent \
  --server ${K3S_URL} \
  --token ${K3S_TOKEN} \
  --node-ip=192.168.20.2X

# Проверка на master-1
kubectl get nodes
# Должны увидеть все 6 нод (3 masters + 3 workers)
```

### 3.5 Установка MetalLB для LoadBalancer

```bash
# На master-1
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Ждем готовности
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Создаем IP pool
cat << EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.20.100-192.168.20.150
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
```

### 3.6 Установка Longhorn для Persistent Storage

```bash
# Установка зависимостей на всех нодах
apt install -y open-iscsi nfs-common

# На master-1
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.5.3/deploy/longhorn.yaml

# Ждем готовности
kubectl -n longhorn-system get pods -w

# Создаем StorageClass по умолчанию
kubectl patch storageclass longhorn -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Доступ к UI через port-forward
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

### 3.7 Установка Ingress Nginx Controller

```bash
# Установка Ingress Nginx
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.5/deploy/static/provider/cloud/deploy.yaml

# Проверка
kubectl get svc -n ingress-nginx
# Должен получить External IP из MetalLB pool

# Patch для использования MetalLB
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec":{"type":"LoadBalancer"}}'
```

## Этап 4: HAProxy + Keepalived для High Availability

### 4.1 Установка HAProxy на обоих нодах

```bash
# На haproxy-1 (192.168.30.10) и haproxy-2 (192.168.30.11)

apt update && apt install -y haproxy keepalived

# Настройка /etc/haproxy/haproxy.cfg
cat << 'EOF' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4000

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

# Stats page
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 30s
    stats admin if TRUE

# GitLab HTTP
frontend gitlab_http
    bind *:80
    mode http
    default_backend gitlab_servers

backend gitlab_servers
    mode http
    balance roundrobin
    option httpchk GET /users/sign_in
    http-check expect status 200
    server gitlab-primary 192.168.10.10:80 check
    server gitlab-secondary 192.168.10.11:80 check backup

# GitLab HTTPS
frontend gitlab_https
    bind *:443
    mode tcp
    default_backend gitlab_https_servers

backend gitlab_https_servers
    mode tcp
    balance roundrobin
    option ssl-hello-chk
    server gitlab-primary 192.168.10.10:443 check
    server gitlab-secondary 192.168.10.11:443 check backup

# Nexus
frontend nexus_http
    bind *:8081
    mode http
    default_backend nexus_servers

backend nexus_servers
    mode http
    balance roundrobin
    option httpchk GET /
    server nexus 192.168.10.20:8081 check

# SonarQube
frontend sonarqube_http
    bind *:9000
    mode http
    default_backend sonarqube_servers

backend sonarqube_servers
    mode http
    balance roundrobin
    option httpchk GET /api/system/status
    server sonarqube 192.168.10.30:9000 check

# Kubernetes API
frontend k8s_api
    bind *:6443
    mode tcp
    default_backend k8s_api_servers

backend k8s_api_servers
    mode tcp
    balance roundrobin
    option tcp-check
    server k3s-master-1 192.168.20.10:6443 check
    server k3s-master-2 192.168.20.11:6443 check
    server k3s-master-3 192.168.20.12:6443 check

# Application Ingress (HTTP)
frontend app_http
    bind *:8080
    mode http
    default_backend ingress_http

backend ingress_http
    mode http
    balance roundrobin
    option httpchk GET /healthz
    server ingress-lb 192.168.20.100:80 check
EOF

systemctl restart haproxy
systemctl enable haproxy
```

### 4.2 Настройка Keepalived

```bash
# На haproxy-1 (192.168.30.10) - MASTER
cat << 'EOF' > /etc/keepalived/keepalived.conf
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass SecurePassword123
    }
    
    virtual_ipaddress {
        192.168.30.1/24
    }
    
    track_script {
        chk_haproxy
    }
}
EOF

# На haproxy-2 (192.168.30.11) - BACKUP
cat << 'EOF' > /etc/keepalived/keepalived.conf
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    
    authentication {
        auth_type PASS
        auth_pass SecurePassword123
    }
    
    virtual_ipaddress {
        192.168.30.1/24
    }
    
    track_script {
        chk_haproxy
    }
}
EOF

# На обоих нодах
systemctl restart keepalived
systemctl enable keepalived

# Проверка VIP
ip addr show eth0 | grep 192.168.30.1
```

## Этап 5: Настройка GitLab CI/CD Integration

### 5.1 Регистрация GitLab Runner в Kubernetes

```bash
# Добавляем Helm repo
helm repo add gitlab https://charts.gitlab.io
helm repo update

# Получаем registration token из GitLab UI
# Settings -> CI/CD -> Runners -> Registration token

# Создаем namespace
kubectl create namespace gitlab-runner

# Устанавливаем GitLab Runner
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  --set gitlabUrl=https://gitlab.yourdomain.com \
  --set runnerRegistrationToken="YOUR_REGISTRATION_TOKEN" \
  --set rbac.create=true \
  --set runners.privileged=true \
  --set runners.cache.cacheType=s3 \
  --set runners.config='
    [[runners]]
      [runners.kubernetes]
        namespace = "gitlab-runner"
        image = "ubuntu:22.04"
        privileged = true
        [[runners.kubernetes.volumes.empty_dir]]
          name = "docker-certs"
          mount_path = "/certs/client"
          medium = "Memory"
  '

# Проверка
kubectl get pods -n gitlab-runner
```

### 5.2 Создание тестового проекта (PetClinic)

```bash
# На локальной машине или bastion host

# Клонируем проект
git clone https://github.com/spring-projects/spring-petclinic.git
cd spring-petclinic

# Настраиваем GitLab remote
git remote remove origin
git remote add origin https://gitlab.yourdomain.com/your-username/spring-petclinic.git

# Создаем .gitlab-ci.yml
cat << 'EOF' > .gitlab-ci.yml
stages:
  - build
  - test
  - quality
  - package
  - deploy

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  NEXUS_URL: "http://192.168.10.20:8081"
  SONAR_URL: "http://192.168.10.30:9000"

cache:
  paths:
    - .m2/repository
    - target/

build:
  stage: build
  image: maven:3.9-openjdk-17
  script:
    - mvn clean compile
  artifacts:
    paths:
      - target/
    expire_in: 1 hour

test:
  stage: test
  image: maven:3.9-openjdk-17
  script:
    - mvn test
  artifacts:
    when: always
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml

sonarqube-check:
  stage: quality
  image: maven:3.9-openjdk-17
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0"
  cache:
    key: "${CI_JOB_NAME}"
    paths:
      - .sonar/cache
  script:
    - mvn verify sonar:sonar
      -Dsonar.projectKey=${CI_PROJECT_NAME}
      -Dsonar.host.url=${SONAR_URL}
      -Dsonar.login=${SONAR_TOKEN}
  allow_failure: true

package:
  stage: package
  image: maven:3.9-openjdk-17
  script:
    - mvn package -DskipTests
    - mvn deploy:deploy-file
      -DgroupId=org.springframework.samples
      -DartifactId=spring-petclinic
      -Dversion=${CI_COMMIT_SHORT_SHA}
      -Dpackaging=jar
      -Dfile=target/spring-petclinic-*.jar
      -DrepositoryId=nexus
      -Durl=${NEXUS_URL}/repository/maven-releases/
  artifacts:
    paths:
      - target/*.jar
    expire_in: 1 week

build-docker:
  stage: package
  image: docker:24-dind
  services:
    - docker:24-dind
  variables:
    DOCKER_TLS_CERTDIR: "/certs"
  script:
    - docker build -t ${NEXUS_URL}:8082/petclinic:${CI_COMMIT_SHORT_SHA} .
    - docker login ${NEXUS_URL}:8082 -u admin -p ${NEXUS_PASSWORD}
    - docker push ${NEXUS_URL}:8082/petclinic:${CI_COMMIT_SHORT_SHA}

deploy-k8s:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl config set-cluster k3s --server=https://192.168.20.10:6443 --insecure-skip-tls-verify=true
    - kubectl config set-credentials gitlab-runner --token=${K8S_TOKEN}
    - kubectl config set-context default --cluster=k3s --user=gitlab-runner
    - kubectl config use-context default
    - |
      cat <<DEPLOY | kubectl apply -f -
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: petclinic
        namespace: default
      spec:
        replicas: 3
        selector:
          matchLabels:
            app: petclinic
        template:
          metadata:
            labels:
              app: petclinic
          spec:
            containers:
            - name: petclinic
              image: ${NEXUS_URL}:8082/petclinic:${CI_COMMIT_SHORT_SHA}
              ports:
              - containerPort: 8080
              resources:
                requests:
                  memory: "512Mi"
                  cpu: "500m"
                limits:
                  memory: "1Gi"
                  cpu: "1000m"
              livenessProbe:
                httpGet:
                  path: /actuator/health
                  port: 8080
                initialDelaySeconds: 60
                periodSeconds: 10
              readinessProbe:
                httpGet:
                  path: /actuator/health
                  port: 8080
                initialDelaySeconds: 30
                periodSeconds: 5
      ---
      apiVersion: v1
      kind: Service
      metadata:
        name: petclinic-service
        namespace: default
      spec:
        selector:
          app: petclinic
        ports:
        - protocol: TCP
          port: 80
          targetPort: 8080
        type: LoadBalancer
      ---
      apiVersion: networking.k8s.io/v1
      kind: Ingress
      metadata:
        name: petclinic-ingress
        namespace: default
        annotations:
          nginx.ingress.kubernetes.io/rewrite-target: /
      spec:
        ingressClassName: nginx
        rules:
        - host: petclinic.yourdomain.com
          http:
            paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: petclinic-service
                  port:
                    number: 80
      DEPLOY
  only:
    - main
EOF

# Создаем Dockerfile для PetClinic
cat << 'EOF' > Dockerfile
FROM openjdk:17-jdk-slim
WORKDIR /app
COPY target/spring-petclinic-*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF

# Коммитим и пушим
git add .
git commit -m "Add CI/CD pipeline configuration"
git push -u origin main
```

### 5.3 Настройка Nexus для Docker Registry

```bash
# Через Nexus UI (http://192.168.30.1:8081)
# 1. Login as admin
# 2. Create Docker (hosted) repository:
#    - Name: docker-hosted
#    - HTTP port: 8082
#    - Enable Docker V1 API: false
#    - Deployment policy: Allow redeploy

# На всех K8s worker нодах добавляем insecure registry
cat << EOF > /etc/rancher/k3s/registries.yaml
mirrors:
  "192.168.10.20:8082":
    endpoint:
      - "http://192.168.10.20:8082"
configs:
  "192.168.10.20:8082":
    auth:
      username: admin
      password: your-nexus-password
EOF

# Перезапуск K3s на workers
systemctl restart k3s-agent

# Создаем Kubernetes secret для Docker registry
kubectl create secret docker-registry nexus-registry \
  --docker-server=192.168.10.20:8082 \
  --docker-username=admin \
  --docker-password=your-nexus-password \
  --namespace=default
```

### 5.4 Настройка SonarQube Token

```bash
# В SonarQube UI (http://192.168.30.1:9000)
# 1. Login as admin
# 2. My Account -> Security -> Generate Token
# 3. Copy token

# В GitLab UI
# Settings -> CI/CD -> Variables
# Add variable:
#   Key: SONAR_TOKEN
#   Value: <your-sonarqube-token>
#   Protected: Yes
#   Masked: Yes
```

## Этап 6: Мониторинг и Observability

### 6.1 Установка Prometheus Stack

```bash
# Добавляем Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Создаем namespace
kubectl create namespace monitoring

# Создаем values.yaml для кастомизации
cat << 'EOF' > prometheus-values.yaml
prometheus:
  prometheusSpec:
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi

grafana:
  enabled: true
  adminPassword: "StrongPassword123"
  persistence:
    enabled: true
    storageClassName: longhorn
    size: 10Gi
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
      - grafana.yourdomain.com

alertmanager:
  enabled: true
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: longhorn
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

kubeStateMetrics:
  enabled: true

nodeExporter:
  enabled: true

prometheusOperator:
  enabled: true
EOF

# Установка
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  -f prometheus-values.yaml

# Проверка
kubectl get pods -n monitoring -w
```

### 6.2 Настройка ServiceMonitor для приложений

```bash
# Создаем ServiceMonitor для PetClinic
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: petclinic-metrics
  namespace: default
  labels:
    app: petclinic
spec:
  selector:
    app: petclinic
  ports:
  - name: metrics
    port: 8080
    targetPort: 8080
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: petclinic-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: petclinic
  namespaceSelector:
    matchNames:
    - default
  endpoints:
  - port: metrics
    path: /actuator/prometheus
    interval: 30s
EOF
```

### 6.3 Мониторинг Infrastructure Services

```bash
# На GitLab VM устанавливаем node_exporter
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
tar xvfz node_exporter-1.7.0.linux-amd64.tar.gz
cp node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/

cat << 'EOF' > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter

# Повторить для Nexus, SonarQube, PostgreSQL, HAProxy VMs

# На Prometheus добавляем scrape configs
kubectl edit configmap prometheus-prometheus-kube-prometheus-prometheus -n monitoring

# Добавляем в scrape_configs:
# - job_name: 'infrastructure'
#   static_configs:
#   - targets:
#     - '192.168.10.10:9100'  # GitLab
#     - '192.168.10.20:9100'  # Nexus
#     - '192.168.10.30:9100'  # SonarQube
#     - '192.168.10.40:9100'  # PostgreSQL
#     - '192.168.30.10:9100'  # HAProxy-1
#     - '192.168.30.11:9100'  # HAProxy-2
```

### 6.4 Установка Loki для логирования

```bash
# Добавляем Helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Создаем values для Loki
cat << 'EOF' > loki-values.yaml
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: longhorn
    size: 50Gi

write:
  replicas: 0

read:
  replicas: 0

backend:
  replicas: 0

monitoring:
  selfMonitoring:
    enabled: false
  lokiCanary:
    enabled: false

test:
  enabled: false
EOF

# Установка Loki
helm install loki grafana/loki \
  --namespace monitoring \
  -f loki-values.yaml

# Установка Promtail для сбора логов
cat << 'EOF' > promtail-values.yaml
config:
  clients:
    - url: http://loki:3100/loki/api/v1/push
  snippets:
    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: __host__
          - action: labelmap
            regex: __meta_kubernetes_pod_label_(.+)
          - action: replace
            replacement: $1
            separator: /
            source_labels:
            - __meta_kubernetes_namespace
            - __meta_kubernetes_pod_name
            target_label: job
EOF

helm install promtail grafana/promtail \
  --namespace monitoring \
  -f promtail-values.yaml
```

## Этап 7: Backup и Disaster Recovery

### 7.1 Backup Strategy для GitLab

```bash
# На GitLab VM создаем скрипт бэкапа
cat << 'EOF' > /usr/local/bin/gitlab-backup.sh
#!/bin/bash
set -e

BACKUP_DIR="/var/opt/gitlab/backups"
RETENTION_DAYS=7
NFS_BACKUP="/mnt/nfs-backup"

# Создаем backup
gitlab-backup create SKIP=registry

# Копируем на NFS
rsync -av ${BACKUP_DIR}/ ${NFS_BACKUP}/gitlab/

# Backup конфигурации
tar -czf ${NFS_BACKUP}/gitlab/gitlab-config-$(date +%Y%m%d).tar.gz \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json

# Очистка старых бэкапов
find ${BACKUP_DIR} -name "*.tar" -mtime +${RETENTION_DAYS} -delete
find ${NFS_BACKUP}/gitlab -name "*.tar" -mtime +${RETENTION_DAYS} -delete

echo "Backup completed: $(date)"
EOF

chmod +x /usr/local/bin/gitlab-backup.sh

# Добавляем в cron (ежедневно в 2 AM)
cat << 'EOF' > /etc/cron.d/gitlab-backup
0 2 * * * root /usr/local/bin/gitlab-backup.sh >> /var/log/gitlab-backup.log 2>&1
EOF
```

### 7.2 Backup для Nexus

```bash
# На Nexus VM
cat << 'EOF' > /usr/local/bin/nexus-backup.sh
#!/bin/bash
set -e

NEXUS_DATA="/opt/sonatype-work/nexus3"
BACKUP_DIR="/mnt/nfs-backup/nexus"
DATE=$(date +%Y%m%d_%H%M%S)

# Создаем backup через Nexus API
curl -u admin:${NEXUS_PASSWORD} -X POST \
  "http://localhost:8081/service/rest/v1/tasks/run/db.backup"

# Ждем завершения задачи
sleep 300

# Копируем бэкап на NFS
rsync -av ${NEXUS_DATA}/backup/ ${BACKUP_DIR}/backup-${DATE}/

# Очистка старых бэкапов (7 дней)
find ${BACKUP_DIR} -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;

echo "Nexus backup completed: $(date)"
EOF

chmod +x /usr/local/bin/nexus-backup.sh

# Cron job (ежедневно в 3 AM)
cat << 'EOF' > /etc/cron.d/nexus-backup
0 3 * * * root /usr/local/bin/nexus-backup.sh >> /var/log/nexus-backup.log 2>&1
EOF
```

### 7.3 Backup PostgreSQL

```bash
# На PostgreSQL VM
cat << 'EOF' > /usr/local/bin/postgres-backup.sh
#!/bin/bash
set -e

BACKUP_DIR="/mnt/nfs-backup/postgresql"
DATE=$(date +%Y%m%d_%H%M%S)

# Backup всех баз
sudo -u postgres pg_dumpall > ${BACKUP_DIR}/all-databases-${DATE}.sql

# Backup отдельных баз
sudo -u postgres pg_dump gitlab_production > ${BACKUP_DIR}/gitlab-${DATE}.sql
sudo -u postgres pg_dump sonarqube > ${BACKUP_DIR}/sonarqube-${DATE}.sql

# Сжатие
gzip ${BACKUP_DIR}/*-${DATE}.sql

# Очистка старых бэкапов
find ${BACKUP_DIR} -name "*.sql.gz" -mtime +7 -delete

echo "PostgreSQL backup completed: $(date)"
EOF

chmod +x /usr/local/bin/postgres-backup.sh

# Cron job
cat << 'EOF' > /etc/cron.d/postgres-backup
0 1 * * * root /usr/local/bin/postgres-backup.sh >> /var/log/postgres-backup.log 2>&1
EOF
```

### 7.4 Kubernetes Backup с Velero

```bash
# На master-1
# Установка Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.1/velero-v1.12.1-linux-amd64.tar.gz
tar -xvf velero-v1.12.1-linux-amd64.tar.gz
mv velero-v1.12.1-linux-amd64/velero /usr/local/bin/

# Установка MinIO на NFS сервере (192.168.10.50)
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio
mv minio /usr/local/bin/

cat << 'EOF' > /etc/systemd/system/minio.service
[Unit]
Description=MinIO
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/minio server /export/minio-data --console-address ":9001"
Restart=on-failure
Environment="MINIO_ROOT_USER=minioadmin"
Environment="MINIO_ROOT_PASSWORD=minioadmin"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now minio

# На K8s master
# Создаем values для Velero
cat << 'EOF' > velero-values.yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: k8s-backups
      config:
        region: minio
        s3ForcePathStyle: true
        s3Url: http://192.168.10.50:9000
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: minio

credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id = minioadmin
      aws_secret_access_key = minioadmin

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.8.0
    volumeMounts:
      - mountPath: /target
        name: plugins

schedules:
  daily-backup:
    schedule: "0 2 * * *"
    template:
      ttl: "168h"
      includedNamespaces:
      - "*"
EOF

helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  -f velero-values.yaml

# Тестовый бэкап
velero backup create test-backup --include-namespaces default
velero backup describe test-backup
```

## Этап 8: Security Hardening

### 8.1 Настройка SSL/TLS сертификатов

```bash
# Установка cert-manager в K8s
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.3/cert-manager.yaml

# Ждем готовности
kubectl wait --for=condition=Available --timeout=300s \
  deployment/cert-manager -n cert-manager

# Создаем ClusterIssuer для Let's Encrypt (если есть публичный домен)
cat << EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@yourdomain.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# Для внутренней сети создаем self-signed issuer
cat << EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

# Обновляем Ingress для использования TLS
cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: petclinic-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: "selfsigned-issuer"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - petclinic.yourdomain.com
    secretName: petclinic-tls
  rules:
  - host: petclinic.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: petclinic-service
            port:
              number: 80
EOF
```

### 8.2 Network Policies

```bash
# Базовая Network Policy для изоляции namespaces
cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-nginx
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: petclinic
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 8080
EOF
```

### 8.3 Pod Security Standards

```bash
# Включаем Pod Security Admission
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF

# Создаем SecurityContext для приложений
cat << EOF > petclinic-secure-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petclinic-secure
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: petclinic
  template:
    metadata:
      labels:
        app: petclinic
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: petclinic
        image: 192.168.10.20:8082/petclinic:latest
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
          readOnlyRootFilesystem: true
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /app/cache
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
      volumes:
      - name: tmp
        emptyDir: {}
      - name: cache
        emptyDir: {}
EOF

kubectl apply -f petclinic-secure-deployment.yaml
```

### 8.4 Secrets Management

```bash
# Установка Sealed Secrets для безопасного хранения секретов в Git
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/controller.yaml

# Установка kubeseal CLI
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.5/kubeseal-0.24.5-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.5-linux-amd64.tar.gz
mv kubeseal /usr/local/bin/

# Пример создания sealed secret
kubectl create secret generic db-credentials \
  --from-literal=username=appuser \
  --from-literal=password=SecurePass123 \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-db-credentials.yaml

# Теперь sealed-db-credentials.yaml можно безопасно commit в Git
kubectl apply -f sealed-db-credentials.yaml
```

## Этап 9: Тестирование и Валидация

### 9.1 Smoke Tests

```bash
# Создаем скрипт для проверки всех компонентов
cat << 'EOF' > /usr/local/bin/infrastructure-health-check.sh
#!/bin/bash

echo "=== Infrastructure Health Check ==="
echo "Date: $(date)"
echo ""

# Check HAProxy VIP
echo "Checking HAProxy VIP..."
ping -c 2 192.168.30.1 && echo "✓ VIP accessible" || echo "✗ VIP failed"
echo ""

# Check GitLab
echo "Checking GitLab..."
curl -s -o /dev/null -w "%{http_code}" http://192.168.30.1 | \
  grep -q "302\|200" && echo "✓ GitLab accessible" || echo "✗ GitLab failed"
echo ""

# Check Nexus
echo "Checking Nexus..."
curl -s -o /dev/null -w "%{http_code}" http://192.168.30.1:8081 | \
  grep -q "200" && echo "✓ Nexus accessible" || echo "✗ Nexus failed"
echo ""

# Check SonarQube
echo "Checking SonarQube..."
curl -s -o /dev/null -w "%{http_code}" http://192.168.30.1:9000 | \
  grep -q "200" && echo "✓ SonarQube accessible" || echo "✗ SonarQube failed"
echo ""

# Check Kubernetes API
echo "Checking Kubernetes..."
kubectl cluster-info && echo "✓ K8s API accessible" || echo "✗ K8s API failed"
echo ""

# Check K8s nodes
echo "Kubernetes Nodes:"
kubectl get nodes
echo ""

# Check K8s pods
echo "Critical Pods Status:"
kubectl get pods -n kube-system
kubectl get pods -n monitoring
kubectl get pods -n ingress-nginx
echo ""

# Check PetClinic deployment
echo "Checking PetClinic Application..."
kubectl get deployment petclinic -n default && \
  echo "✓ PetClinic deployed" || echo "✗ PetClinic not found"
echo ""

# Check MetalLB
echo "Checking LoadBalancer Services..."
kubectl get svc -A | grep LoadBalancer
echo ""

# Check storage
echo "Checking Persistent Volumes..."
kubectl get pv
echo ""

echo "=== Health Check Complete ==="
EOF

chmod +x /usr/local/bin/infrastructure-health-check.sh

# Запускаем проверку
/usr/local/bin/infrastructure-health-check.sh
```

### 9.2 Load Testing

```bash
# Установка k6 для load testing
apt install -y gpg
gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
  tee /etc/apt/sources.list.d/k6.list
apt update && apt install -y k6

# Создаем load test script
cat << 'EOF' > petclinic-load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '2m', target: 50 },  // Ramp up to 50 users
    { duration: '5m', target: 50 },  // Stay at 50 users
    { duration: '2m', target: 100 }, // Ramp up to 100 users
    { duration: '5m', target: 100 }, // Stay at 100 users
    { duration: '2m', target: 0 },   // Ramp down to 0 users
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'], // 95% of requests should be below 500ms
    http_req_failed: ['rate<0.01'],   // Error rate should be less than 1%
  },
};

export default function () {
  const res = http.get('http://petclinic.yourdomain.com');
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  
  sleep(1);
}
EOF

# Запуск load test
k6 run petclinic-load-test.js
```

## Итоговый Checklist

```markdown
# Production Readiness Checklist

## Infrastructure Components
- [ ] Все VLAN настроены и протестированы
- [ ] NFS storage смонтирован на всех требуемых нодах
- [ ] DNS записи настроены (если применимо)
- [ ] Правила firewall реализованы
- [ ] Network policies протестированы

## Stateful Services
- [ ] PostgreSQL кластер операционен и протестирован
- [ ] PostgreSQL backups работают автоматически
- [ ] GitLab установлен и доступен
- [ ] GitLab backup cron job настроен
- [ ] Nexus repository операционен
- [ ] Nexus Docker registry настроен
- [ ] SonarQube установлен и настроен
- [ ] Все сервисы доступны через HAProxy VIP

## High Availability
- [ ] HAProxy VRRP failover протестирован
- [ ] Keepalived VIP переходит плавно
- [ ] K3s 3-master HA операционен
- [ ] K3s API доступен через все masters
- [ ] etcd cluster health проверен
- [ ] Worker node failure обрабатывается корректно

## Kubernetes Cluster
- [ ] Все 6 нод (3 masters + 3 workers) присоединены
- [ ] MetalLB IP pool настроен (192.168.20.100-150)
- [ ] Ingress Nginx controller развернут
-
