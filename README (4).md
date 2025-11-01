# Spring PetClinic CI/CD Pipeline на Proxmox

Подробная инструкция по развертыванию end-to-end CI/CD pipeline с GitLab, Kubernetes, Maven, Nexus, SonarQube на домашнем Proxmox сервере.

## Архитектура решения

### Компоненты инфраструктуры
- **GitLab CE** - система управления репозиториями и CI/CD
- **Kubernetes (K3s)** - оркестрация контейнеров (аналог DigitalOcean Kubernetes)
- **Nexus Repository** - хранилище артефактов
- **SonarQube** - анализ качества кода
- **GitLab Runner** - исполнитель CI/CD задач
- **HAProxy** - load balancer для доступа к сервисам

### Сетевая топология

Internet (серый IP) → Router (10.0.10.1) → Proxmox (10.0.10.200)

↓

| Внутренняя сеть 10.0.10.0/24 |
|---|
| GitLab VM: 10.0.10.10 |
| K3s Master: 10.0.10.20 |
| K3s Worker-1: 10.0.10.21 |
| K3s Worker-2: 10.0.10.22 |
| HAProxy LB: 10.0.10.30 |

---

## Часть 1: Подготовка виртуальных машин

### 1.1 Требования к VM

| VM | CPU | RAM | Disk | OS |
|---|---|---|---|---|
| GitLab | 4 | 8GB | 50GB | Ubuntu 22.04 |
| K3s Master | 2 | 4GB | 40GB | Ubuntu 22.04 |
| K3s Worker-1 | 2 | 8GB | 60GB | Ubuntu 22.04 |
| K3s Worker-2 | 2 | 8GB | 60GB | Ubuntu 22.04 |
| HAProxy | 1 | 2GB | 20GB | Ubuntu 22.04 |

### 1.2 Terraform конфигурация для Proxmox

```hcl
terraform {
  required_providers {
    proxmox = {
      source = "telmate/proxmox"
      version = "2.9.14"
    }
  }
}

provider "proxmox" {
  pm_api_url = "https://10.0.10.200:8006/api2/json"
  pm_user = "root@pam"
  pm_password = "your-password"
  pm_tls_insecure = true
}

# Cloud-init template (создание заранее)
variable "template_name" {
  default = "ubuntu-2204-cloudinit-template"
}

# GitLab VM
resource "proxmox_vm_qemu" "gitlab" {
  name = "gitlab"
  target_node = "pve"
  clone = var.template_name

  cores = 4
  memory = 8192
  scsihw = "virtio-scsi-pci"

  disk {
    size = "50G"
    type = "scsi"
    storage = "local-lvm"
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=10.0.10.10/24,gw=10.0.10.1"
  nameserver = "8.8.8.8"
  ssh_user = "ubuntu"
  sshkeys = file("~/.ssh/id_rsa.pub")
}

# K3s Master
resource "proxmox_vm_qemu" "k3s_master" {
  name = "k3s-master"
  target_node = "pve"
  clone = var.template_name

  cores = 2
  memory = 4096

  disk {
    size = "40G"
    type = "scsi"
    storage = "local-lvm"
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=10.0.10.20/24,gw=10.0.10.1"
  nameserver = "8.8.8.8"
  ssh_user = "ubuntu"
  sshkeys = file("~/.ssh/id_rsa.pub")
}

# K3s Worker-1
resource "proxmox_vm_qemu" "k3s_worker1" {
  name = "k3s-worker1"
  target_node = "pve"
  clone = var.template_name

  cores = 2
  memory = 8192

  disk {
    size = "60G"
    type = "scsi"
    storage = "local-lvm"
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=10.0.10.21/24,gw=10.0.10.1"
  nameserver = "8.8.8.8"
  ssh_user = "ubuntu"
  sshkeys = file("~/.ssh/id_rsa.pub")
}

# K3s Worker-2
resource "proxmox_vm_qemu" "k3s_worker2" {
  name = "k3s-worker2"
  target_node = "pve"
  clone = var.template_name

  cores = 2
  memory = 8192

  disk {
    size = "60G"
    type = "scsi"
    storage = "local-lvm"
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=10.0.10.22/24,gw=10.0.10.1"
  nameserver = "8.8.8.8"
  ssh_user = "ubuntu"
  sshkeys = file("~/.ssh/id_rsa.pub")
}

# HAProxy LB
resource "proxmox_vm_qemu" "haproxy" {
  name = "haproxy"
  target_node = "pve"
  clone = var.template_name

  cores = 1
  memory = 2048

  disk {
    size = "20G"
    type = "scsi"
    storage = "local-lvm"
  }

  network {
    model = "virtio"
    bridge = "vmbr0"
  }

  ipconfig0 = "ip=10.0.10.30/24,gw=10.0.10.1"
  nameserver = "8.8.8.8"
  ssh_user = "ubuntu"
  sshkeys = file("~/.ssh/id_rsa.pub")
}

output "vm_ips" {
  value = {
    gitlab = "10.0.10.10"
    k3s_master = "10.0.10.20"
    k3s_worker1 = "10.0.10.21"
    k3s_worker2 = "10.0.10.22"
    haproxy = "10.0.10.30"
  }
}
```
1.3 Создание Cloud-Init шаблона
На Proxmox хосте:
bash
# Скачать Ubuntu Cloud Image
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img

# Создать VM для шаблона
qm create 9000 --name ubuntu-2204-cloudinit-template --memory 2048 --net0 virtio,bridge=vmbr0
qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1

# Конвертировать в шаблон
qm template 9000
1.4 Развертывание VM через Terraform
На Windows машине:
bash
# Инициализация
terraform init

# Планирование
terraform plan

# Применение
terraform apply -auto-approve

# Проверка доступности
ping 10.0.10.10
ping 10.0.10.20
Часть 2: Установка GitLab CE
2.1 Подключение к GitLab VM
bash
ssh ubuntu@10.0.10.10
2.2 Установка GitLab
bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка зависимостей
sudo apt install -y curl openssh-server ca-certificates tzdata perl

# Добавление репозитория GitLab
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash

# Установка GitLab CE
sudo EXTERNAL_URL="http://10.0.10.10" apt install gitlab-ce

# Получение пароля root
sudo cat /etc/gitlab/initial_root_password
2.3 Настройка GitLab
bash
# Редактирование конфигурации
sudo nano /etc/gitlab/gitlab.rb
Измените следующие параметры:

ruby
external_url 'http://gitlab.local.lab'
gitlab_rails['gitlab_shell_ssh_port'] = 22
gitlab_rails['time_zone'] = 'Asia/Almaty'

# Настройка памяти
puma['worker_processes'] = 2
sidekiq['max_concurrency'] = 10

# Отключение неиспользуемых компонентов
prometheus_monitoring['enable'] = false
grafana['enable'] = false
Примените изменения:

bash
sudo gitlab-ctl reconfigure
sudo gitlab-ctl restart
2.4 Настройка hosts на Windows
Запустите Notepad от имени администратора:
Откройте файл C:\Windows\System32\drivers\etc\hosts

Добавьте записи:

text
10.0.10.10 gitlab.local.lab
10.0.10.30 petclinic.local.lab
10.0.10.30 nexus.local.lab
10.0.10.30 sonarqube.local.lab
Часть 3: Установка K3s Kubernetes
3.1 Установка K3s Master
bash
ssh ubuntu@10.0.10.20

# Установка K3s
curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --node-ip 10.0.10.20 \
  --node-external-ip 10.0.10.20

# Получение токена для worker нод
sudo cat /var/lib/rancher/k3s/server/node-token

# Копирование kubeconfig
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown ubuntu:ubuntu ~/.kube/config

# Проверка
kubectl get nodes
3.2 Установка K3s Workers
Worker-1:
bash
ssh ubuntu@10.0.10.21

# Установка (замените TOKEN на значение из master)
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.10.20:6443 \
  K3S_TOKEN="YOUR_TOKEN_HERE" sh -
Worker-2:
bash
ssh ubuntu@10.0.10.22

# Установка
curl -sfL https://get.k3s.io | K3S_URL=https://10.0.10.20:6443 \
  K3S_TOKEN="YOUR_TOKEN_HERE" sh -
Проверка на Master:
bash
kubectl get nodes
# Должны появиться все 3 ноды
3.3 Установка MetalLB (LoadBalancer)
bash
# На K3s Master
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Дождитесь готовности пода
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s
Создайте файл metallb-config.yaml:

yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 10.0.10.100-10.0.10.150

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
Примените:

bash
kubectl apply -f metallb-config.yaml
Часть 4: Установка Helm
4.1 На K3s Master
bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Проверка
helm version
4.2 На Windows машине
Скачайте Helm для Windows: https://github.com/helm/helm/releases

Распакуйте и добавьте в PATH, либо через Chocolatey:

powershell
choco install kubernetes-helm
4.3 Копирование kubeconfig на Windows
На K3s Master:

bash
cat ~/.kube/config
На Windows:

Создайте файл C:\Users\YourUser\.kube\config и вставьте содержимое, заменив:

yaml
server: https://127.0.0.1:6443
на:

yaml
server: https://10.0.10.20:6443
Проверьте подключение:

powershell
kubectl get nodes
Часть 5: Установка SonarQube
5.1 Добавление Helm репозитория
bash
ssh ubuntu@10.0.10.20

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube
helm repo update
5.2 Подготовка конфигурации
Создайте sonarqube-values.yaml:

yaml
service:
  type: LoadBalancer
  loadBalancerIP: 10.0.10.101

resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: 2000m
    memory: 4Gi

persistence:
  enabled: true
  storageClass: "local-path"
  size: 20Gi

postgresql:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
5.3 Установка
bash
kubectl create namespace sonarqube

helm install sonarqube sonarqube/sonarqube \
  --namespace sonarqube \
  -f sonarqube-values.yaml

# Проверка
kubectl get pods -n sonarqube
kubectl get svc -n sonarqube
5.4 Получение пароля
Дождитесь запуска (может занять 5-10 минут):

bash
kubectl wait --for=condition=ready pod \
  -l app=sonarqube \
  -n sonarqube \
  --timeout=600s
Доступ:

URL: http://10.0.10.101:9000

Login: admin

Password: admin (измените при первом входе)

Часть 6: Установка Nexus Repository
6.1 Добавление репозитория
bash
helm repo add sonatype https://sonatype.github.io/helm3-charts/
helm repo update
6.2 Подготовка конфигурации
Создайте nexus-values.yaml:

yaml
service:
  type: LoadBalancer
  loadBalancerIP: 10.0.10.102

resources:
  requests:
    cpu: 500m
    memory: 2Gi
  limits:
    cpu: 2000m
    memory: 4Gi

persistence:
  enabled: true
  storageClass: "local-path"
  storageSize: 50Gi

nexus:
  env:
  - name: INSTALL4J_ADD_VM_PARAMS
    value: "-Xms1200M -Xmx1200M -XX:MaxDirectMemorySize=2G"
6.3 Установка
bash
kubectl create namespace nexus

helm install nexus sonatype/nexus-repository-manager \
  --namespace nexus \
  -f nexus-values.yaml

# Проверка
kubectl get pods -n nexus
kubectl get svc -n nexus
6.4 Получение пароля
bash
# Дождитесь готовности
kubectl wait --for=condition=ready pod \
  -l app=nexus-repository-manager \
  -n nexus \
  --timeout=600s

# Получите имя пода
POD_NAME=$(kubectl get pods -n nexus -l app=nexus-repository-manager -o jsonpath='{.items[0].metadata.name}')

# Получите пароль
kubectl exec -n nexus $POD_NAME -- cat /nexus-data/admin.password
Доступ:

URL: http://10.0.10.102:8081

Login: admin

Password: (из команды выше)

Часть 7: Настройка HAProxy
7.1 Установка HAProxy
bash
ssh ubuntu@10.0.10.30
sudo apt update
sudo apt install -y haproxy
7.2 Конфигурация
bash
sudo nano /etc/haproxy/haproxy.cfg
Добавьте в конец файла:

haproxy
frontend http_front
  bind *:80
  mode http
  acl is_nexus hdr(host) -i nexus.local.lab
  acl is_sonar hdr(host) -i sonarqube.local.lab
  acl is_petclinic hdr(host) -i petclinic.local.lab
  use_backend nexus_back if is_nexus
  use_backend sonar_back if is_sonar
  use_backend petclinic_back if is_petclinic

backend nexus_back
  mode http
  balance roundrobin
  server nexus 10.0.10.102:8081 check

backend sonar_back
  mode http
  balance roundrobin
  server sonar 10.0.10.101:9000 check

backend petclinic_back
  mode http
  balance roundrobin
  server petclinic 10.0.10.103:80 check
Перезапустите HAProxy:

bash
sudo systemctl restart haproxy
sudo systemctl enable haproxy
sudo systemctl status haproxy
Часть 8: Настройка Nexus Repository
8.1 Вход в Nexus
Откройте http://nexus.local.lab в браузере, войдите с admin и паролем.

8.2 Создание Maven репозиториев
Перейдите в Settings → Repositories → Create repository

Создайте maven2 (hosted) с именем maven-hosted-release:

Version policy: Release

Deployment policy: Disable redeploy

Создайте maven2 (hosted) с именем maven-hosted-snapshot:

Version policy: Snapshot

Deployment policy: Allow redeploy

8.3 Создание Docker репозитория (опционально)
Create repository → docker (hosted)

Name: docker-hosted

HTTP: 8082

Enable Docker V1 API: ✓

Часть 9: Настройка SonarQube
9.1 Вход в SonarQube
Откройте http://sonarqube.local.lab, войдите (admin/admin), смените пароль.

9.2 Создание проекта
Нажмите Create Project → Manually

Project key: spring-petclinic

Display name: Spring PetClinic

Нажмите Set Up

9.3 Генерация токена
Выберите Locally

Generate token: gitlab-ci

Validity: 30 days

Generate и скопируйте токен

9.4 Создание Quality Gate (опционально)
Quality Gates → Create

Name: GitLab CI Gate

Добавьте условия:

Coverage < 80% (Warning)

Bugs > 0 (Error)

Code Smells > 5 (Warning)

Часть 10: Настройка GitLab CI/CD
10.1 Создание проекта в GitLab
Откройте http://gitlab.local.lab

Создайте новый проект: spring-petclinic

Visibility: Public

10.2 Настройка CI/CD переменных
Перейдите в Settings → CI/CD → Variables:

Key	Value	Masked	Protected
NEXUS_USER	admin	No	No
NEXUS_PASSWORD	(ваш пароль)	Yes	No
SONAR_HOST_URL	http://10.0.10.101:9000	No	No
SONAR_TOKEN	(токен из SonarQube)	Yes	No
CI_REGISTRY	https://index.docker.io/v1/	No	No
CI_REGISTRY_USER	(Docker Hub username)	No	No
CI_REGISTRY_PASSWORD	(Docker Hub token)	Yes	No
KUBECONFIG	(содержимое ~/.kube/config)	No	No
Для KUBECONFIG:

Type: File

Value: Содержимое kubeconfig с master ноды

10.3 Клонирование проекта
На Windows:

bash
git clone https://github.com/spring-projects/spring-petclinic.git
cd spring-petclinic
10.4 Изменение pom.xml
Добавьте в <properties>:

xml
<nexus.host.url>http://10.0.10.102:8081</nexus.host.url>
Добавьте после </repositories>:

xml
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
10.5 Создание Maven settings.xml
Создайте .m2/settings.xml:

xml
<settings>
  <servers>
    <server>
      <id>nexus</id>
      <username>${env.NEXUS_USER}</username>
      <password>${env.NEXUS_PASSWORD}</password>
    </server>
  </servers>
</settings>
10.6 Создание sonar-project.properties
properties
sonar.projectKey=spring-petclinic
sonar.projectName=spring-petclinic
sonar.projectVersion=1.0
sonar.sources=src/main
sonar.tests=src/test
sonar.java.binaries=target/classes
sonar.language=java
sonar.sourceEncoding=UTF-8
sonar.java.libraries=target/classes
10.7 Создание Dockerfile
dockerfile
FROM openjdk:8-jre-alpine
EXPOSE 8080
COPY target/*.war /usr/bin/spring-petclinic.war
ENTRYPOINT ["java", "-jar", "/usr/bin/spring-petclinic.war", "--server.port=8080"]
10.8 Создание Helm Chart
bash
mkdir -p petclinic-chart/templates
petclinic-chart/Chart.yaml:

yaml
apiVersion: v2
name: petclinic
description: Spring PetClinic Application
version: 1.0.0
appVersion: "1.0"
petclinic-chart/values.yaml:

yaml
image:
  repository: yourdockerhubuser/spring-petclinic
  tag: latest
  pullPolicy: Always

service:
  type: LoadBalancer
  loadBalancerIP: 10.0.10.103
  port: 80
  targetPort: 8080

replicaCount: 1
petclinic-chart/templates/deployment.yaml:

yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
petclinic-chart/templates/service.yaml:

yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}
spec:
  type: {{ .Values.service.type }}
  loadBalancerIP: {{ .Values.service.loadBalancerIP }}
  selector:
    app: {{ .Chart.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
10.9 Создание .gitlab-ci.yml
Создайте .gitlab-ci.yml в корне проекта:

yaml
variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  M2_EXTRA: "-s .m2/settings.xml"
  IMAGE_NAME: "spring-petclinic"
  TAG: "$CI_COMMIT_SHA"

image: maven:3.8.2-openjdk-11

stages:
  - build
  - test
  - quality
  - package
  - dockerize
  - deploy

cache:
  paths:
    - .m2/repository

build_job:
  stage: build
  script:
    - echo "Building application..."
    - mvn $M2_EXTRA clean compile
  artifacts:
    paths:
      - target/

test_job:
  stage: test
  script:
    - echo "Running tests..."
    - mvn $M2_EXTRA test
  dependencies:
    - build_job

sonar_scan:
  stage: quality
  image:
    name: sonarsource/sonar-scanner-cli:latest
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0"
  script:
    - sonar-scanner -Dsonar.qualitygate.wait=true
  dependencies:
    - build_job
  allow_failure: false

package_job:
  stage: package
  script:
    - echo "Packaging application..."
    - mvn $M2_EXTRA package -DskipTests
    - ls -l target/*.war
  artifacts:
    paths:
      - target/*.war
    expire_in: 1 week
  dependencies:
    - build_job

push_to_nexus:
  stage: package
  script:
    - echo "Deploying to Nexus..."
    - mvn $M2_EXTRA deploy -DskipTests
  dependencies:
    - package_job
  only:
    - main
    - master

dockerize:
  stage: dockerize
  image:
    name: gcr.io/kaniko-project/executor:v1.9.0-debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"${CI_REGISTRY}\":{\"auth\":\"$(printf "%s:%s" "${CI_REGISTRY_USER}" "${CI_REGISTRY_PASSWORD}" | base64 | tr -d '\n')\"}}}" > /kaniko/.docker/config.json
    - /kaniko/executor
      --context "${CI_PROJECT_DIR}"
      --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
      --destination "${CI_REGISTRY_USER}/${IMAGE_NAME}:${TAG}"
      --destination "${CI_REGISTRY_USER}/${IMAGE_NAME}:latest"
  dependencies:
    - package_job
  only:
    - main
    - master

deploy_to_k8s:
  stage: deploy
  image: kunchalavikram/kubectl_helm_cli:latest
  script:
    - mkdir -p ~/.kube
    - cat $KUBECONFIG > ~/.kube/config
    - helm upgrade --install petclinic ./petclinic-chart
      --set image.tag=${TAG}
      --set image.repository=${CI_REGISTRY_USER}/${IMAGE_NAME}
      --namespace default
  environment:
    name: production
    url: http://petclinic.local.lab
  only:
    - main
    - master
  when: manual
10.10 Отправка кода в GitLab
bash
git remote remove origin
git remote add origin http://gitlab.local.lab/root/spring-petclinic.git
git add .
git commit -m "Initial commit with CI/CD pipeline"
git push -u origin master
Часть 11: Установка GitLab Runner в Kubernetes
11.1 Добавление Helm репозитория GitLab
bash
ssh ubuntu@10.0.10.20

helm repo add gitlab https://charts.gitlab.io
helm repo update
11.2 Получение Registration Token
Откройте GitLab: http://gitlab.local.lab

Перейдите в Admin Area (гаечный ключ) → CI/CD → Runners

Скопируйте Registration token

11.3 Подготовка values для Runner
Создайте gitlab-runner-values.yaml:

yaml
gitlabUrl: http://10.0.10.10/
runnerRegistrationToken: "YOUR_REGISTRATION_TOKEN_HERE"

rbac:
  create: true

runners:
  config: |
    [[runners]]
      [runners.kubernetes]
        namespace = "{{.Release.Namespace}}"
        image = "ubuntu:22.04"
        privileged = true
        [[runners.kubernetes.volumes.empty_dir]]
          name = "docker-certs"
          mount_path = "/certs/client"
          medium = "Memory"
  tags: "k8s,kubernetes"
  runUntagged: true
  locked: false

resources:
  limits:
    memory: 256Mi
    cpu: 200m
  requests:
    memory: 128Mi
    cpu: 100m
11.4 Установка Runner
bash
kubectl create namespace gitlab-runner

helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  -f gitlab-runner-values.yaml

# Проверка
kubectl get pods -n gitlab-runner
kubectl logs -n gitlab-runner -l app=gitlab-runner-gitlab-runner
11.5 Проверка регистрации
Вернитесь в GitLab Admin Area → CI/CD → Runners. Вы должны увидеть новый Runner с тегом k8s.

Настройка Runner:

Нажмите на Runner

Установите:

✓ Run untagged jobs

✓ Lock to current projects (снимите)

Maximum job timeout: 3600

Часть 12: Адаптация Pipeline для Kubernetes Runner
12.1 Обновление .gitlab-ci.yml для использования Runner
Измените .gitlab-ci.yml:

yaml
variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  M2_EXTRA: "-s .m2/settings.xml"
  IMAGE_NAME: "spring-petclinic"
  TAG: "$CI_COMMIT_SHA"

default:
  tags:
    - k8s

image: maven:3.8.2-openjdk-11

stages:
  - build
  - test
  - quality
  - package
  - dockerize
  - deploy

cache:
  paths:
    - .m2/repository

build_job:
  stage: build
  script:
    - echo "Building application..."
    - mvn $M2_EXTRA clean compile
  artifacts:
    paths:
      - target/
    expire_in: 1 hour

test_job:
  stage: test
  script:
    - echo "Running tests..."
    - mvn $M2_EXTRA test
  artifacts:
    reports:
      junit:
        - target/surefire-reports/TEST-*.xml
  dependencies:
    - build_job

sonar_scan:
  stage: quality
  image:
    name: sonarsource/sonar-scanner-cli:latest
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0"
  script:
    - sonar-scanner
      -Dsonar.projectKey=spring-petclinic
      -Dsonar.sources=src/main
      -Dsonar.java.binaries=target/classes
      -Dsonar.host.url=${SONAR_HOST_URL}
      -Dsonar.login=${SONAR_TOKEN}
      -Dsonar.qualitygate.wait=true
  dependencies:
    - build_job
  allow_failure: true

package_job:
  stage: package
  script:
    - echo "Packaging application..."
    - mvn $M2_EXTRA package -DskipTests
    - ls -lh target/*.war
  artifacts:
    paths:
      - target/*.war
    expire_in: 1 week
  dependencies:
    - build_job

push_to_nexus:
  stage: package
  script:
    - echo "Deploying artifacts to Nexus..."
    - mvn $M2_EXTRA deploy -DskipTests
  dependencies:
    - package_job
  only:
    - main
    - master

dockerize:
  stage: dockerize
  image:
    name: gcr.io/kaniko-project/executor:v1.9.0-debug
    entrypoint: [""]
  before_script:
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"${CI_REGISTRY}\":{\"auth\":\"$(printf "%s:%s" "${CI_REGISTRY_USER}" "${CI_REGISTRY_PASSWORD}" | base64 | tr -d '\n')\"}}}" > /kaniko/.docker/config.json
  script:
    - /kaniko/executor
      --context "${CI_PROJECT_DIR}"
      --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
      --destination "${CI_REGISTRY_USER}/${IMAGE_NAME}:${TAG}"
      --destination "${CI_REGISTRY_USER}/${IMAGE_NAME}:latest"
  dependencies:
    - package_job
  only:
    - main
    - master

deploy_to_k8s:
  stage: deploy
  image:
    name: alpine/k8s:1.21.14
    entrypoint: [""]
  before_script:
    - apk add --no-cache helm
    - mkdir -p /root/.kube
    - echo "$KUBECONFIG" > /root/.kube/config
    - chmod 600 /root/.kube/config
  script:
    - echo "Deploying to Kubernetes..."
    - helm upgrade --install petclinic ./petclinic-chart
      --set image.tag=${TAG}
      --set image.repository=${CI_REGISTRY_USER}/${IMAGE_NAME}
      --namespace default
      --wait
    - echo "Application deployed successfully!"
  environment:
    name: production
    url: http://petclinic.local.lab
  only:
    - main
    - master
  when: manual
12.2 Отправка изменений
bash
git add .
git commit -m "Update CI/CD for Kubernetes runner"
git push origin master
Часть 13: Мониторинг и отладка
13.1 Мониторинг Pipeline
Перейдите в GitLab → CI/CD → Pipelines

Нажмите на текущий pipeline для просмотра логов

13.2 Отладка Kubernetes
bash
# Проверка подов
kubectl get pods --all-namespaces

# Логи пода
kubectl logs -f <pod-name>

# Описание пода для диагностики
kubectl describe pod <pod-name>

# Проверка сервисов
kubectl get svc --all-namespaces

# Проверка ingress
kubectl get ingress --all-namespaces
13.3 Отладка GitLab Runner
bash
# Проверка состояния Runner
kubectl get pods -n gitlab-runner

# Логи Runner
kubectl logs -n gitlab-runner -f <runner-pod-name>

# Проверка конфигурации
kubectl describe pod -n gitlab-runner <runner-pod-name>
13.4 Проверка доступа к приложению
После успешного деплоя:

bash
# Проверка сервиса PetClinic
kubectl get svc petclinic

# Должен показать EXTERNAL-IP: 10.0.10.103
curl http://10.0.10.103

# Или через HAProxy
curl -H "Host: petclinic.local.lab" http://10.0.10.30
Часть 14: Расширенные настройки
14.1 Настройка SSL/TLS (опционально)
Для продакшн среды рекомендуется настроить SSL:

bash
# Установка cert-manager
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.12.0/cert-manager.yaml

# Создание ClusterIssuer для Let's Encrypt
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
14.2 Настройка мониторинга с Prometheus
bash
# Установка Prometheus Stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin
14.3 Настройка резервного копирования
Для Nexus и SonarQube:

bash
# Создание скрипта бэкапа
cat > /home/ubuntu/backup.sh << 'EOF'
#!/bin/bash
DATE=$(date +%Y%m%d_%H%M%S)

# Бэкап Nexus
kubectl exec -n nexus $(kubectl get pods -n nexus -l app=nexus-repository-manager -o jsonpath='{.items[0].metadata.name}') -- tar czf /tmp/nexus-backup-$DATE.tar.gz /nexus-data
kubectl cp nexus/$(kubectl get pods -n nexus -l app=nexus-repository-manager -o jsonpath='{.items[0].metadata.name}'):/tmp/nexus-backup-$DATE.tar.gz /home/ubuntu/backups/nexus-backup-$DATE.tar.gz

# Бэкап SonarQube (PostgreSQL)
kubectl exec -n sonarqube $(kubectl get pods -n sonarqube -l app=postgresql -o jsonpath='{.items[0].metadata.name}') -- pg_dump -U sonar sonar > /home/ubuntu/backups/sonar-db-$DATE.sql
EOF

chmod +x /home/ubuntu/backup.sh
Часть 15: Тестирование полного Pipeline
15.1 Создание тестового коммита
bash
# Внесите небольшое изменение в код
echo "# Test commit for CI/CD" >> README.md
git add README.md
git commit -m "Test CI/CD pipeline"
git push origin master
15.2 Мониторинг выполнения
GitLab: CI/CD → Pipelines

Kubernetes: kubectl get pods -w

SonarQube: Проверьте качество кода

Nexus: Проверьте артефакты

15.3 Проверка деплоя
После успешного выполнения pipeline:

bash
# Проверка приложения
curl http://petclinic.local.lab

# Или через браузер
# Откройте http://petclinic.local.lab
Заключение
Вы успешно развернули полноценный CI/CD pipeline на базе Proxmox VE с использованием:

✅ GitLab CE - система управления кодом и CI/CD

✅ Kubernetes (K3s) - оркестрация контейнеров

✅ Nexus Repository - хранение артефактов

✅ SonarQube - анализ качества кода

✅ HAProxy - балансировка нагрузки

✅ GitLab Runner в Kubernetes - исполнение CI/CD задач

Преимущества решения:
Полная изоляция - все компоненты в домашней сети

Автоматизация - end-to-end pipeline от коммита до деплоя

Масштабируемость - легко добавить новые ноды/сервисы

Экономия - бесплатное ПО, использование существующего железа

Профессиональный стек - enterprise-уровень инструментов

Дальнейшие улучшения:
Настройка SSL/TLS сертификатов

Внедрение мониторинга (Prometheus/Grafana)

Настройка оповещений

Реализация Blue-Green деплоя

Настройка автоматического масштабирования (HPA)

Теперь у вас есть полноценная DevOps платформа для разработки и развертывания приложений!
