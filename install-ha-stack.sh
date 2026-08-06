#!/usr/bin/env bash
#
# install-ha-stack.sh
# Installe Docker CE + Home Assistant Container + Mosquitto (MQTT) sur Debian 13.
# Compatible amd64 (ThinkPad) et arm64 (Raspberry Pi 5) : Docker gère l'archi automatiquement.
#
# Usage : sudo ./install-ha-stack.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être lancé avec sudo : sudo ./install-ha-stack.sh"
  exit 1
fi

TZ_VALUE="Europe/Paris"
HA_CONFIG_DIR="/opt/homeassistant/config"
MQ_BASE_DIR="/opt/mosquitto"
MQTT_UID=1883
MQTT_USER="homeassistant"

echo "==> [1/6] Installation de Docker CE"
if ! command -v docker &> /dev/null; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  echo "    Docker déjà installé, on passe."
fi

echo "==> [2/6] Vérification du daemon Docker"
docker run --rm hello-world > /dev/null
echo "    Docker fonctionne correctement."

echo "==> [3/6] Préparation de Mosquitto (config + dossiers)"
mkdir -p "${MQ_BASE_DIR}/config" "${MQ_BASE_DIR}/data" "${MQ_BASE_DIR}/log"

if [[ ! -f "${MQ_BASE_DIR}/config/mosquitto.conf" ]]; then
  cat > "${MQ_BASE_DIR}/config/mosquitto.conf" <<EOF
listener 1883
allow_anonymous false
password_file /mosquitto/config/pwfile
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF
fi

# Droits corrects dès le départ pour éviter les crash loops (UID mosquitto = 1883 dans l'image)
chown -R "${MQTT_UID}:${MQTT_UID}" "${MQ_BASE_DIR}"

echo "==> [4/6] Lancement du container Mosquitto"
docker rm -f mosquitto &> /dev/null || true
docker run -d \
  --name mosquitto \
  --restart=unless-stopped \
  -p 1883:1883 \
  -v "${MQ_BASE_DIR}/config:/mosquitto/config" \
  -v "${MQ_BASE_DIR}/data:/mosquitto/data" \
  -v "${MQ_BASE_DIR}/log:/mosquitto/log" \
  eclipse-mosquitto

sleep 2

# Créer l'utilisateur MQTT si le fichier de mots de passe est vide/absent
if [[ ! -s "${MQ_BASE_DIR}/config/pwfile" ]]; then
  echo "==> Création de l'utilisateur MQTT '${MQTT_USER}'"
  read -rsp "    Choisis un mot de passe MQTT pour '${MQTT_USER}' : " MQTT_PASS
  echo
  rm -f "${MQ_BASE_DIR}/config/pwfile"
  docker exec mosquitto mosquitto_passwd -b -c /mosquitto/config/pwfile "${MQTT_USER}" "${MQTT_PASS}"
  chown "${MQTT_UID}:${MQTT_UID}" "${MQ_BASE_DIR}/config/pwfile"
  docker restart mosquitto
  echo "    Utilisateur MQTT créé : ${MQTT_USER} / (mot de passe saisi)"
else
  echo "    Fichier pwfile déjà présent, utilisateur MQTT non recréé."
fi

echo "==> [5/6] Lancement du container Home Assistant"
mkdir -p "${HA_CONFIG_DIR}"
docker rm -f homeassistant &> /dev/null || true
docker run -d \
  --name homeassistant \
  --privileged \
  --restart=unless-stopped \
  -e TZ="${TZ_VALUE}" \
  -v "${HA_CONFIG_DIR}:/config" \
  --network=host \
  ghcr.io/home-assistant/home-assistant:stable

echo "==> [6/6] Vérification finale"
sleep 5
docker ps --filter "name=homeassistant" --filter "name=mosquitto"

cat <<EOF

--------------------------------------------------------
Installation terminée.

Home Assistant : http://localhost:8123
  -> Premier lancement : crée ton compte via l'écran "Bienvenue !"

MQTT (broker Mosquitto) : localhost:1883
  -> Utilisateur : ${MQTT_USER}
  -> À renseigner dans HA via Paramètres > Appareils et services > Ajouter une intégration > MQTT

Pense à noter le compte HA et le mot de passe MQTT quelque part sûr.
--------------------------------------------------------
EOF
