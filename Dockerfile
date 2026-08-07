FROM python:3.12-slim

# cysystemd necessite des headers systemd + un compilateur pour se construire
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libsystemd-dev gcc pkg-config && \
    pip install --no-cache-dir pyserial crcmod mppsolar cysystemd && \
    apt-get purge -y build-essential gcc pkg-config && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# Patch du bug connu de mppsolar : la variable 'pause' n'est initialisee
# que si un fichier de config (-C) est fourni, ce qui plante le mode --daemon
# sans fichier de config. On l'initialise depuis la variable d'env LOOP_PAUSE.
RUN PYFILE=$(python3 -c "import mppsolar, os; print(os.path.join(os.path.dirname(mppsolar.__file__), '__init__.py'))") && \
    sed -i '/if args.configfile:/i\    pause = int(os.environ.get("LOOP_PAUSE", "60"))' "$PYFILE" && \
    python3 -m py_compile "$PYFILE"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
