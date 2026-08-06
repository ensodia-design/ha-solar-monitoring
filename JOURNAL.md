# Journal de bord — Projet Raspberry Pi 5 / Home Assistant / Supervision solaire

Ce document retrace toutes les étapes réalisées, les problèmes rencontrés et
leurs solutions, depuis l'installation de Home Assistant jusqu'au versionning
des scripts. Objectif final : superviser une installation solaire (onduleur
Voltronic MAX 8000W + batteries Pylontech US3000) à Saly, Sénégal, via un
Raspberry Pi 5.

Tests réalisés sur un ThinkPad (Debian 13 / Trixie, x86_64) avant transposition
identique sur le Pi 5 (arm64).

---

## 1. Architecture cible

```
Onduleur Voltronic MAX (RS232, protocole PI30)
        |
        v
mppsolar (lit le port serie, decode le protocole PI30)
        |
        v
Mosquitto (broker MQTT, container Docker)
        |
        v
Home Assistant (container Docker, auto-discovery MQTT)
```

Trois containers Docker tournent en parallele : `homeassistant`, `mosquitto`,
et (plus tard, sur le vrai materiel) `inverter-homeassistant` ou `mppsolar`
en mode daemon.

---

## 2. Installation de base (Docker + Home Assistant + Mosquitto)

### 2.1 Docker CE

```bash
sudo apt update && sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

**Piege rencontre** : la premiere tentative visait "Home Assistant Supervised"
(paquet `.deb`), une methode beaucoup plus lourde (reproduit un mini-HAOS,
necessite `os-agent`, AppArmor, NetworkManager...). Objectif reel = simple
supervision d'un onduleur, donc **Home Assistant Container** (Docker simple)
est largement suffisant et plus fiable sur un OS generique.

### 2.2 Home Assistant Container

```bash
sudo mkdir -p /opt/homeassistant/config
sudo docker run -d \
  --name homeassistant \
  --privileged \
  --restart=unless-stopped \
  -e TZ=Europe/Paris \
  -v /opt/homeassistant/config:/config \
  --network=host \
  ghcr.io/home-assistant/home-assistant:stable
```

Acces web : `http://localhost:8123`

### 2.3 Mosquitto (broker MQTT)

```bash
sudo mkdir -p /opt/mosquitto/{config,data,log}

cat << 'EOF' | sudo tee /opt/mosquitto/config/mosquitto.conf
listener 1883
allow_anonymous false
password_file /mosquitto/config/pwfile
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
EOF

# IMPORTANT : donner les bons droits AVANT de lancer le container
sudo chown -R 1883:1883 /opt/mosquitto

sudo docker run -d \
  --name mosquitto \
  --restart=unless-stopped \
  -p 1883:1883 \
  -v /opt/mosquitto/config:/mosquitto/config \
  -v /opt/mosquitto/data:/mosquitto/data \
  -v /opt/mosquitto/log:/mosquitto/log \
  eclipse-mosquitto

# Creation de l'utilisateur MQTT (le fichier pwfile ne doit PAS exister avant)
sudo docker exec -it mosquitto mosquitto_passwd -c /mosquitto/config/pwfile homeassistant
sudo docker restart mosquitto
```

Puis dans Home Assistant : **Parametres > Appareils et services > Ajouter une
integration > MQTT**, broker `localhost`, port `1883`, utilisateur
`homeassistant`, mot de passe choisi.

Script complet automatisant ces etapes : voir `install-ha-stack.sh` dans ce
depot.

---

## 3. Problemes rencontres et solutions

| Probleme | Cause | Solution |
|---|---|---|
| `dpkg: os-agent n'est pas installe` | Tentative Home Assistant *Supervised* (mauvaise methode pour ce cas d'usage) | Abandon au profit de Home Assistant *Container* (Docker) |
| `permission denied ... docker.sock` | Commande Docker lancee sans `sudo` | Ajouter `sudo`, ou ajouter l'utilisateur au groupe `docker` |
| Mosquitto en crash loop, `Unable to open log file` | Dossiers `/opt/mosquitto/*` appartenant a `root`, alors que le process container tourne en UID `1883` | `sudo chown -R 1883:1883 /opt/mosquitto` **avant** de lancer le container |
| `mosquitto_passwd: File exists` | Fichier `pwfile` deja cree (vide) avant d'utiliser l'option `-c` (creation) | Supprimer le fichier vide avant de relancer `mosquitto_passwd -c` |
| HA : "Nom d'utilisateur ou mot de passe invalide" | Confusion entre le compte de connexion HA (cree a l'onboarding) et le compte MQTT (`homeassistant`/`saraba`) — ce sont deux comptes distincts | Se connecter avec le compte HA, reserver les identifiants MQTT a l'integration MQTT uniquement |
| `Unable to fetch auth providers` | Fichiers d'authentification HA (`.storage/auth`, `auth_provider.homeassistant`, `onboarding`) renommes de facon incoherente pendant un depannage | Redemarrer le container ; si necessaire, mettre ces 3 fichiers de cote et relancer l'onboarding a zero |

---

## 4. Simuler l'onduleur sans materiel (mock inverter)

Objectif : valider toute la chaine logicielle (lecture serie -> MQTT -> HA)
**avant** d'avoir le Raspberry Pi 5 et le cable RS232.

### 4.1 Principe

Un port serie virtuel (paire reliee via `socat`) remplace le vrai cable USB
vers l'onduleur. Un script Python (`mock_inverter.py`, dans ce depot) se fait
passer pour l'onduleur et repond aux commandes du protocole **PI30**
(Voltronic/Axpert) avec des valeurs plausibles (tension batterie, SOC,
puissance PV...), CRC16/XModem inclus.

```bash
sudo apt install -y socat
pip install pyserial crcmod mppsolar --break-system-packages

# 1) Creer la paire de ports virtuels
socat -d -d pty,raw,echo=0,link=/tmp/ttyV0 pty,raw,echo=0,link=/tmp/ttyV1 &

# 2) Lancer le faux onduleur (terminal dedie)
python3 mock_inverter.py /tmp/ttyV1

# 3) Interroger depuis un autre terminal
~/.local/bin/mppsolar -p /tmp/ttyV0 -P PI30 -c QPIGS --porttype serial
```

### 4.2 Publier vers MQTT / Home Assistant

```bash
~/.local/bin/mppsolar -p /tmp/ttyV0 -P PI30 -c QPIGS --porttype serial \
  -o hass_mqtt -q 127.0.0.1 --mqttport 1883 --mqttuser homeassistant --mqttpass saraba \
  --daemon
```

Resultat obtenu : ~30 entites creees automatiquement dans HA via
l'auto-discovery MQTT (`Parametres > Appareils et services > MQTT`).

### 4.3 Bugs rencontres dans `mppsolar` (version testee) et corrections

| Symptome | Cause | Solution |
|---|---|---|
| Package `mpp-solar` introuvable sur PyPI | Le projet a ete renomme `mppsolar` (sans tiret) | `pip install mppsolar` |
| `No communications port defined` | Detection automatique du type de port basee sur le nom du fichier (doit contenir "serial", "ttyusb", etc.) ; `/tmp/ttyV0` ne correspond a aucun motif | Ajouter `--porttype serial` explicitement |
| `Cannot publish ... not connected` (usage ponctuel `-c QPIGS` sans `--daemon`) | La connexion MQTT s'etablit dans un thread separe ; en mode "une commande", le programme tente de publier et quitte avant que la connexion soit prete | Utiliser `--daemon` (boucle), qui laisse le temps a la connexion de s'etablir aux iterations suivantes |
| `Connection refused` avec `-q localhost` | `localhost` se resout en IPv6 (`::1`) en priorite ; le broker n'ecoute qu'en IPv4 | Utiliser `-q 127.0.0.1` explicitement |
| `error: No module named 'cysystemd'` avec `--daemon` | Dependance manquante pour l'integration systemd (notify/watchdog) | `sudo apt install build-essential libsystemd-dev && pip install cysystemd --break-system-packages` |
| `UnboundLocalError: cannot access local variable 'pause'` en boucle | Bug reel du paquet : la variable `pause` n'est initialisee que si un fichier de config (`-C`) est fourni | Patch manuel : ajouter `pause = 60` (ou une valeur plus courte type `10`) juste avant `if args.configfile:` dans `mppsolar/__init__.py` (ligne ~458 selon version) |

---

## 5. Versionning avec Git / GitHub Desktop

### 5.1 Mise en place

1. Depot cree sur github.com : `ensodia-design/ha-solar-monitoring`
2. Clone local via GitHub Desktop : **File > Clone Repository > GitHub.com**
3. Application ouverte via terminal a cause d'un souci d'affichage GPU (Intel
   Ivy Bridge) : `github-desktop --disable-gpu &`

### 5.2 Workflow de base

1. Copier/modifier des fichiers dans le dossier local du depot
   (`~/projects/ha-solar-monitoring/`)
2. GitHub Desktop detecte automatiquement les changements (onglet **Changes**)
3. Ecrire un message de commit (**Summary**)
4. **Commit to main**
5. **Push origin** (bouton en haut a droite, remplace "Fetch origin" une fois
   qu'il y a des commits locaux non pousses)

### 5.3 Point de vigilance : secrets

Ne jamais committer de fichiers contenant des mots de passe en clair
(`secrets.yaml`, `pwfile`, logs contenant des tokens). Un `.gitignore` dedie
doit exclure : `secrets.yaml`, `*.log`, `*.db`, `*.db-shm`, `*.db-wal`,
`pwfile`, `.env`.

---

## 6. Prochaines etapes (Raspberry Pi 5, materiel reel)

- [ ] Reproduire `install-ha-stack.sh` sur le Pi 5 (arm64, meme script,
      Docker gere l'architecture automatiquement)
- [ ] Cable RS232 (RJ45) vers USB specifique Voltronic pour relier le Pi 5 a
      l'onduleur physique a Saly
- [ ] Remplacer `/tmp/ttyV0` (simulation) par le vrai port
      `/dev/serial/by-id/usb-...`
- [ ] Deployer `mppsolar` (ou `inverter-homeassistant`) en service permanent
      (systemd ou container avec passthrough du device USB) plutot qu'en
      commande manuelle
- [ ] Verifier le comportement reel face aux variations solaires
      (production, charge/decharge batterie) — la simulation ne peut pas
      remplacer ce test en conditions reelles

---

*Document redige le 6 aout 2026, a l'issue de la session d'installation et de
mise en main initiale.*
