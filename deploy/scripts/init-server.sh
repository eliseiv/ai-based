#!/usr/bin/env bash
# Первичная настройка сервера Ubuntu 22.04+ для AI-Backend.
# Запускать один раз от sudo-пользователя на свежей машине.
set -euo pipefail

DEPLOY_DIR="/opt/aibased"
DEPLOY_USER="${DEPLOY_USER:-$USER}"

log() { printf '\n\033[1;36m[init-server]\033[0m %s\n' "$*"; }

require_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        log "Запущено от root. Рекомендуется создать обычного sudo-юзера и запускать от него."
    fi
    sudo -v
}

apt_update() {
    log "Обновляю apt и базовые утилиты"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl gnupg ufw fail2ban unattended-upgrades htop git jq
}

setup_swap() {
    if swapon --show | grep -q '/swapfile'; then
        log "Swap уже настроен"
        return
    fi
    log "Создаю swap 2GB (диск всего 15GB — нужно для билдов и LLM-всплесков)"
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    fi
    sudo sysctl vm.swappiness=10 || true
    echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
}

install_docker() {
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        log "Docker и compose уже установлены"
        return
    fi
    log "Ставлю Docker Engine и compose-плагин"
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.asc ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo tee /etc/apt/keyrings/docker.asc >/dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.asc
    fi
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo usermod -aG docker "$DEPLOY_USER" || true
    sudo systemctl enable --now docker

    log "Настраиваю log-rotation для docker (10MB × 3)"
    sudo mkdir -p /etc/docker
    sudo tee /etc/docker/daemon.json >/dev/null <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
    sudo systemctl restart docker
}

setup_firewall() {
    log "Настраиваю UFW: 22/tcp, 80/tcp, 443/tcp"
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow 22/tcp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw --force enable
}

setup_unattended_upgrades() {
    log "Включаю автоматические security-обновления"
    sudo dpkg-reconfigure -f noninteractive unattended-upgrades || true
    echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' | \
        sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
}

prepare_deploy_dir() {
    log "Готовлю каталог $DEPLOY_DIR"
    sudo mkdir -p "$DEPLOY_DIR"/{nginx/conf.d,nginx/conf.d.bootstrap,certbot/conf,certbot/www,scripts}
    sudo chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$DEPLOY_DIR"
}

setup_disk_cleanup_cron() {
    log "Добавляю еженедельную очистку старых docker-образов"
    CRON_LINE="0 4 * * 0 /usr/bin/docker image prune -af --filter \"until=72h\" >/var/log/docker-prune.log 2>&1"
    ( sudo crontab -l 2>/dev/null | grep -v 'docker image prune' ; echo "$CRON_LINE" ) | sudo crontab -
}

main() {
    require_sudo
    apt_update
    setup_swap
    install_docker
    setup_firewall
    setup_unattended_upgrades
    prepare_deploy_dir
    setup_disk_cleanup_cron

    log "Готово. Перелогиньтесь (или выполните 'newgrp docker'), чтобы получить группу docker без sudo."
    log "Дальше: загрузите содержимое каталога deploy/ в $DEPLOY_DIR и запустите init-letsencrypt.sh"
}

main "$@"
