#!/bin/sh
set -eu

: "${SERIAL_PORT:=/dev/ttyUSB0}"
: "${PROTOCOL:=PI30}"
: "${MQTT_HOST:=mosquitto}"
: "${MQTT_PORT:=1883}"
: "${MQTT_USER:=homeassistant}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD doit etre defini (voir .env)}"

echo "[mppsolar] Port serie : ${SERIAL_PORT}"
echo "[mppsolar] Protocole  : ${PROTOCOL}"
echo "[mppsolar] Broker MQTT: ${MQTT_HOST}:${MQTT_PORT}"

exec mppsolar \
  -p "${SERIAL_PORT}" \
  -P "${PROTOCOL}" \
  -c QPIGS \
  --porttype serial \
  -o hass_mqtt \
  -q "${MQTT_HOST}" \
  --mqttport "${MQTT_PORT}" \
  --mqttuser "${MQTT_USER}" \
  --mqttpass "${MQTT_PASSWORD}" \
  --daemon
