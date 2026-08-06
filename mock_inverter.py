#!/usr/bin/env python3
"""
mock_inverter.py
Simule un onduleur Voltronic MAX (protocole PI30) sur un port série virtuel,
pour tester toute la chaine logicielle (lecture série -> MQTT -> Home Assistant)
sans avoir le Raspberry Pi ni l'onduleur physique.

Prérequis :
  sudo apt install socat
  pip install pyserial crcmod --break-system-packages

Utilisation :
  1) Créer une paire de ports série virtuels reliés entre eux :
       socat -d -d pty,raw,echo=0,link=/tmp/ttyV0 pty,raw,echo=0,link=/tmp/ttyV1 &

  2) Lancer ce script sur le port "cote onduleur" :
       python3 mock_inverter.py /tmp/ttyV1

  3) Pointer l'outil de lecture (mpp-solar) sur le port "cote lecteur" :
       mpp-solar -p /tmp/ttyV0 -P PI30 -c QPIGS
"""
import sys
import time
import serial
import crcmod

crc16 = crcmod.predefined.mkCrcFun("xmodem")


def with_crc(payload: bytes) -> bytes:
    """Ajoute le CRC16/XModem + retour chariot, comme le fait un vrai onduleur PI30."""
    crc = crc16(payload).to_bytes(2, "big")
    return payload + crc + b"\r"


# Trame QPIGS réaliste pour un systeme 8kW / batteries Pylontech 48V / PV ~8.1 kWc
# (valeurs plausibles en pleine journee, charge en cours)
QPIGS_RESPONSE = with_crc(
    b"(230.0 50.0 230.0 50.0 1200 1100 015 410 53.20 025 078 0450 0055 180.5 53.10 00000 10010110 00 00 03200 010"
)

# Reponses minimales pour quelques autres commandes utiles
RESPONSES = {
    b"QPIGS": QPIGS_RESPONSE,
    b"QPI": with_crc(b"(PI30"),
    b"QID": with_crc(b"(9293333010051"),
    b"QMOD": with_crc(b"(S"),  # S = Standby ; L = Line mode ; B = Battery mode
}


def find_command(raw: bytes):
    """Les 2 derniers octets avant \\r sont le CRC (binaire) : on identifie la commande par prefixe."""
    for cmd in RESPONSES:
        if raw.startswith(cmd):
            return cmd
    return None


def main():
    if len(sys.argv) != 2:
        print("Usage : python3 mock_inverter.py /chemin/vers/port_serie_virtuel")
        sys.exit(1)

    port_path = sys.argv[1]
    ser = serial.Serial(port_path, baudrate=2400, timeout=1)
    print(f"[mock_inverter] En ecoute sur {port_path} (Ctrl+C pour arreter)")

    buffer = b""
    try:
        while True:
            chunk = ser.read(64)
            if chunk:
                buffer += chunk
                if b"\r" in buffer:
                    frame, _, buffer = buffer.partition(b"\r")
                    cmd = find_command(frame)
                    if cmd:
                        print(f"[mock_inverter] Commande recue : {cmd.decode()} -> reponse envoyee")
                        ser.write(RESPONSES[cmd])
                    else:
                        print(f"[mock_inverter] Commande inconnue ({frame!r}) -> NAK")
                        ser.write(with_crc(b"(NAK"))
            else:
                time.sleep(0.05)
    except KeyboardInterrupt:
        print("\n[mock_inverter] Arret.")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
