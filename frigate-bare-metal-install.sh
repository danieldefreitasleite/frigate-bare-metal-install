#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
echo "libedgetpu1-max libedgetpu/accepted-eula boolean true" | debconf-set-selections  # redundante, mas cobre variações

# ==============================================================================
# FRIGATE BARE METAL INSTALLER (V110 - MENUS RESTORED)
# ==============================================================================
# OS: Debian 12 (Bookworm)
# FIXES:
# 1. RESTORED: Interactive Version, Auth, and Config Mode menus.
# 2. RETAINED: Fixes from old script (RAM Cache, S6 patching, Dependencies).
# 3. RETAINED: RootFS structure preservation.
# ==============================================================================

# --- CONFIGURATION ---
INSTALL_BASE="/opt/frigate"
WEB_DIST="$INSTALL_BASE/web_dist"
#CONFIG_DIR="/etc/frigate"
MEDIA_DIR="/media/frigate"
CONFIG_DIR="$MEDIA_DIR/config"
DATABASE_DIR="$INSTALL_BASE/database"
LOG_FILE="/var/log/frigate_install.log"
STATE_FILE="$INSTALL_BASE/.install_state"
FRIGATE_REPO="https://github.com/blakeblackshear/frigate"
PYTHON_EXEC="python3"
TIMEZONE="America/Sao_Paulo"
HTTP_PORT=5000
S6_VERSION="3.1.6.2"
S6_DEST="/opt/frigate/service"
S6_SRC="$INSTALL_BASE/repo/docker/main/rootfs/etc/s6-overlay/s6-rc.d"

# --- ARCHITECTURE ---
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then 
    export TARGETARCH="amd64"
    S6_ARCH="x86_64"
else 
    export TARGETARCH="arm64"
    S6_ARCH="aarch64"
fi

# --- LOGGING ---
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
log() { echo -e "\n\033[0;32m[INFO] $1\033[0m"; }
error() { echo -e "\n\033[0;31m[ERROR] $1\033[0m"; exit 1; }
GREEN='\033[0;32m'
NC='\033[0m'

is_step_done() {
    if [ -f "$STATE_FILE" ] && grep -q "^$1$" "$STATE_FILE"; then return 0; else return 1; fi
}
mark_step_done() {
    echo "$1" >> "$STATE_FILE"
}

if [[ $EUID -ne 0 ]]; then error "Run as root."; fi

# --- MOCK ENV TRAP ---
MOCK_FILE="/etc/apt/sources.list.d/debian.sources"
CREATED_MOCK=0
setup_mock() {
    if [ ! -f "$MOCK_FILE" ]; then
        mkdir -p /etc/apt/sources.list.d
        cat <<EOF > "$MOCK_FILE"
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm
Components: main
EOF
        CREATED_MOCK=1
    fi
}
cleanup_mock() {
    if [ "$CREATED_MOCK" == "1" ] && [ -f "$MOCK_FILE" ]; then rm "$MOCK_FILE"; fi
}
trap cleanup_mock EXIT

# --- CLEANUP ---
cleanup_temp() {
    log "Cleaning up temp files..."
    rm -rf /tmp/s* /tmp/n* /tmp/p* /tmp/libedgetpu* /tmp/ffmpeg* /tmp/yamnet* 2>/dev/null
}

# --- CLEANUP START ---
log "Stopping services..."
# 1. INITIAL CLEANUP
log "Stopping services..."
systemctl stop frigate-s6 frigate nginx go2rtc 2>/dev/null
rm -f /etc/systemd/system/frigate.service /etc/systemd/system/nginx.service /etc/systemd/system/go2rtc.service
systemctl daemon-reload
cleanup_temp
mkdir -p "$INSTALL_BASE"

log "Starting Install (V110)..."

log "Installing Minimal Tools (curl, jq, git)..."
apt-get update
apt-get install -y curl jq git debconf-utils || error "Failed to install minimal dependencies."

# 2. INTERACTIVE SELECTION
log "Fetching Versions..."
TAGS_JSON=$(curl -s "https://api.github.com/repos/blakeblackshear/frigate/tags")
LATEST_STABLE=$(echo "$TAGS_JSON" | jq -r '.[].name' | grep -v "beta" | grep -v "rc" | sort -V | tail -n 1)
LATEST_BETA=$(echo "$TAGS_JSON" | jq -r '.[].name' | grep -E "beta|rc" | sort -V | tail -n 1)

echo -e "\n----------------------------------------------------"
echo "1) Stable: $LATEST_STABLE (Default)"
echo "2) Beta:   $LATEST_BETA"
echo "----------------------------------------------------"
read -p "Select version [1 or 2]: " CHOICE < /dev/tty
CHOICE=${CHOICE:-1} 

case $CHOICE in
    1) TARGET_VERSION=$LATEST_STABLE ;;
    2) TARGET_VERSION=$LATEST_BETA ;;
    *) TARGET_VERSION=$LATEST_STABLE ;;
esac
log "Selected Version: $TARGET_VERSION"

echo -e "\n----------------------------------------------------"
echo "Authentication Settings"
echo "----------------------------------------------------"
echo "1) Disable Authentication (Default)"
echo "2) Enable Authentication"
echo "----------------------------------------------------"
read -p "Select option [1 or 2]: " AUTH_CHOICE < /dev/tty
AUTH_CHOICE=${AUTH_CHOICE:-1}

if [ "$AUTH_CHOICE" -eq 2 ]; then
    AUTH_ENABLED="True"
else
    AUTH_ENABLED="False"
fi

# echo -e "\n----------------------------------------------------"
# echo "Initial Configuration Strategy"
# echo "----------------------------------------------------"
# echo "1) Demo Mode (Installs sample video)"
# echo "2) Clean Install (No Cameras) - (Default)"
# echo "----------------------------------------------------"
# read -p "Select option [1 or 2]: " CONFIG_MODE < /dev/tty
# CONFIG_MODE=${CONFIG_MODE:-2} # Default to Clean to avoid db corruption
CONFIG_MODE=0

# 3. BOOTSTRAP DEPS
if is_step_done "bootstrap_deps"; then
    log "[Skipping] Bootstrap Dependencies."
else
    log "Installing Bootstrap Tools..."
    if [ -f "/etc/apt/sources.list" ]; then sed -i '/^deb /p; s/^deb /deb-src /' /etc/apt/sources.list; fi
    apt-get update
    # Added autoconf, automake, libtool for libusb compilation
    apt-get install -y wget gnupg ca-certificates lsb-release pkg-config unzip \
        build-essential libpcre3 libpcre3-dev zlib1g zlib1g-dev libssl-dev \
        python3 python3-pip python3-venv python3-dev \
        cargo rustc clang libsqlite3-dev cmake net-tools xz-utils \
        autoconf automake libtool
    mark_step_done "bootstrap_deps"
fi

# 4. CLONE REPO
mkdir -p "$INSTALL_BASE/repo"
if [ -d "$INSTALL_BASE/repo/.git" ]; then
    log "Repo exists. Updating..."
												  
    cd "$INSTALL_BASE/repo"
    git fetch --all
    git reset --hard
    git clean -fd
    git checkout "$TARGET_VERSION"
else
    log "Cloning fresh..."
    git clone "$FRIGATE_REPO" "$INSTALL_BASE/repo"
    cd "$INSTALL_BASE/repo"
				   
    git checkout "$TARGET_VERSION"
fi

chmod +x "$INSTALL_BASE/repo/docker/main/"*.sh

if [ ! -L "/opt/frigate/frigate" ]; then
    ln -sf "$INSTALL_BASE/repo/frigate" "/opt/frigate/frigate"
fi

# 5. EXECUTE OFFICIAL DEPENDENCY SCRIPT
if is_step_done "official_deps_script"; then
					   
									 
    log "[Skipping] Official install_deps.sh"
else
    log "Executing docker/main/install_deps.sh..."
    cd "$INSTALL_BASE/repo"
    setup_mock
    ./docker/main/install_deps.sh || error "Official install_deps.sh failed."
    mark_step_done "official_deps_script"
fi

# 6. INSTALL CORAL LIBUSB & MODELS (Fixed Directory Navigation)
if is_step_done "libusb_coral"; then
    log "[Skipping] LibUSB and Coral Models."
else
    log "Installing LibUSB and Coral Models (This takes time)..."
    cd /opt/frigate
    export CCACHE_DIR=/root/.ccache
    export CCACHE_MAXSIZE=2G
    
    # LibUSB Compilation
    log "Compiling LibUSB 1.0.26..."
    curl -fsSL "https://github.com/libusb/libusb/archive/v1.0.26.zip" -o "v1.0.26.zip"
    unzip -q v1.0.26.zip
    rm v1.0.26.zip
    cd libusb-1.0.26
    ./bootstrap.sh >/dev/null
    ./configure --disable-udev --enable-shared >/dev/null
    make -j $(nproc --all) >/dev/null
    
    # [CRITICAL FIX] Enter the subdir so ../libtool works
    cd libusb
    
    # Install LibUSB
    mkdir -p /usr/local/lib
    /bin/bash ../libtool --mode=install /usr/bin/install -c libusb-1.0.la '/usr/local/lib'
    mkdir -p /usr/local/include/libusb-1.0
    /usr/bin/install -c -m 644 libusb.h '/usr/local/include/libusb-1.0'
    ldconfig
    
    # Models Download
    cd /
    log "Downloading Models..."
    curl -fsSL "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess_edgetpu.tflite" -o "/opt/frigate/edgetpu_model.tflite"
    curl -fsSL "https://github.com/google-coral/test_data/raw/release-frogfish/ssdlite_mobiledet_coco_qat_postprocess.tflite" -o "/opt/frigate/cpu_model.tflite"
    
    # Yamnet / Audio
    cd /tmp
    curl -fsSL "https://www.kaggle.com/api/v1/models/google/yamnet/tfLite/classification-tflite/1/download" -o "yamnet.tar.gz"
    tar xzf yamnet.tar.gz
    mv 1.tflite /opt/frigate/cpu_audio_model.tflite
    rm -rf yamnet.tar.gz
    
    # Links
    ln -sf /opt/frigate/edgetpu_model.tflite /edgetpu_model.tflite
    ln -sf /opt/frigate/cpu_model.tflite /cpu_model.tflite
    ln -sf /opt/frigate/cpu_audio_model.tflite /cpu_audio_model.tflite
    
    if [ -f "/opt/frigate/repo/labelmap.txt" ]; then cp /opt/frigate/repo/labelmap.txt /labelmap.txt; fi
    # Some versions have audio-labelmap, some don't. Try copy.
    if [ -f "/opt/frigate/repo/audio-labelmap.txt" ]; then cp /opt/frigate/repo/audio-labelmap.txt /audio-labelmap.txt; fi
    
    mark_step_done "libusb_coral"
fi	 

# 7. ROOTFS APPLY
log "Applying RootFS..."
cp -a "$INSTALL_BASE/repo/docker/main/rootfs/." /
chmod +x /usr/local/bin/* 2>/dev/null
chmod +x /usr/local/nginx/sbin/nginx 2>/dev/null

# 8. BUILDS
[ ! -L "/opt/frigate/frigate" ] && ln -sf "$INSTALL_BASE/repo/frigate" "/opt/frigate/frigate"
cd "$INSTALL_BASE/repo"

if is_step_done "nginx_build" && [ -x "/usr/local/nginx/sbin/nginx" ]; then
    log "[Skipping] Nginx Build"
else
    log "Building Nginx (Official)..."
    if ./docker/main/build_nginx.sh; then
        ln -sf /usr/local/nginx/sbin/nginx /usr/sbin/nginx
        mark_step_done "nginx_build"
    else
        error "Nginx build failed."
    fi
fi

if is_step_done "sqlite_vec_build" && [ -f "/usr/local/lib/vec0.so" ]; then
    log "[Skipping] Sqlite-Vec Build"
else
    log "Building Sqlite-Vec (Official)..."
    if ./docker/main/build_sqlite_vec.sh; then
        FOUND=$(find / -name "vec0.so" 2>/dev/null | head -n 1)
        if [ -n "$FOUND" ]; then
            mkdir -p /usr/local/lib
            cp "$FOUND" /usr/local/lib/vec0.so
            mark_step_done "sqlite_vec_build"
        else
            error "vec0.so not found."
        fi
    else
        error "Sqlite-vec build failed."
    fi
fi

# 10. GO2RTC INSTALLATION
if is_step_done "go2rtc_install" && [ -f "/usr/local/bin/go2rtc" ]; then
    log "[Skipping] Go2RTC Install"
else
	log "Installing Go2RTC..."
	mkdir -p /usr/local/go2rtc/bin
	GO2RTC_TAG=$(curl -s https://api.github.com/repos/AlexxIT/go2rtc/releases/latest | jq -r .tag_name)
	curl -L -o /usr/local/go2rtc/bin/go2rtc "https://github.com/AlexxIT/go2rtc/releases/download/${GO2RTC_TAG}/go2rtc_linux_${TARGETARCH}"
	chmod +x /usr/local/go2rtc/bin/go2rtc

    ln -sf /usr/local/go2rtc/bin/go2rtc "$INSTALL_BASE/go2rtc"
    ln -sf /usr/local/go2rtc/bin/go2rtc /usr/local/bin/go2rtc
	
    mark_step_done "go2rtc_install"
fi

# 11. TEMPIO INSTALLATION
if is_step_done "tempio_install"; then
    log "[Skipping] Tempio Install."
else
    log "Installing Tempio..."
	mkdir -p /usr/local/tempio/bin
    #TEMPIO_VER="2021.09.0" #from frigate install file 
    TEMPIO_VER="2024.11.2"
    curl -L "https://github.com/home-assistant/tempio/releases/download/${TEMPIO_VER}/tempio_${TARGETARCH}" -o /usr/local/tempio/bin/tempio
    chmod +x /usr/local/tempio/bin/tempio

    ln -sf /usr/local/tempio/bin/tempio "$INSTALL_BASE/tempio"
    ln -sf /usr/local/tempio/bin/tempio /usr/local/bin/tempio

    mark_step_done "tempio_install"
fi	

# 12. PYTHON ENV
log "Configuring Python..."
if [ ! -d "$INSTALL_BASE/venv" ]; then "$PYTHON_EXEC" -m venv "$INSTALL_BASE/venv"; fi
source "$INSTALL_BASE/venv/bin/activate"
pip install --upgrade pip wheel setuptools scikit-build

if is_step_done "python_deps"; then
    log "[Skipping] Python Dependencies"
    pip install jinja2 ruamel.yaml
else
    log "Building Pysqlite3 & Installing Deps..."
    cd "$INSTALL_BASE/repo"
    
    if [ -f "docker/main/build_pysqlite3.sh" ]; then
        ./docker/main/build_pysqlite3.sh
        WHEEL=$(find . -name "pysqlite3_binary*.whl" | head -n 1)
        if [ -n "$WHEEL" ]; then pip install "$WHEEL"; else pip install pysqlite3-binary; fi
    fi

    log "Installing Requirements..."
    PIP_CMD="pip install jinja2 ruamel.yaml" 
    if [ -f "docker/main/requirements-wheels.txt" ]; then PIP_CMD+=" -r docker/main/requirements-wheels.txt"; fi
    if [ -f "requirements.txt" ]; then
        PIP_CMD+=" -r requirements.txt"
    elif [ -f "docker/main/requirements.txt" ]; then
        PIP_CMD+=" -r docker/main/requirements.txt"
    fi
    if [ -f "docker/main/requirements-ov.txt" ]; then
        grep -vE "tensorflow|openvino-dev" docker/main/requirements-ov.txt > /tmp/req_ov_clean.txt
        PIP_CMD+=" -r /tmp/req_ov_clean.txt"
    fi
    $PIP_CMD || error "Pip install failed."
    mark_step_done "python_deps"
fi

# 13. FRONTEND
if is_step_done "frontend_build" && [ -f "$WEB_DIST/index.html" ]; then
    log "[Skipping] Frontend Build"
else
    log "Building Frontend..."
    mkdir -p "$WEB_DIST"
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
        npm install -g npm@latest
    fi
    cd "$INSTALL_BASE/repo/web"
    npm install
    npm run build
    
    if [ -d "dist/BASE_PATH/monacoeditorwork" ]; then
        log "Moving Monaco assets..."
        mkdir -p dist/assets
        mv dist/BASE_PATH/monacoeditorwork/* dist/assets/
        rm -rf dist/BASE_PATH
    fi
    cp -r dist/* "$WEB_DIST/"
    mark_step_done "frontend_build"
fi

rm -rf "$INSTALL_BASE/web"
ln -sf "$WEB_DIST" "$INSTALL_BASE/web"
#ln -sf "$WEB_DIST" "$INSTALL_BASE/repo/frigate/web"


SITE_PACKAGES=$(find "$INSTALL_BASE/venv/lib" -name "site-packages" | head -n 1)
echo "$INSTALL_BASE/repo" > "$SITE_PACKAGES/frigate_source.pth"

# 14. S6 SERVICE CONSTRUCTION
log "Constructing S6 Services..."
cd /tmp
wget -qO s6.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-noarch.tar.xz"
wget -qO s6-arch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/v${S6_VERSION}/s6-overlay-${S6_ARCH}.tar.xz"
tar -C / -Jxpf s6.tar.xz
tar -C / -Jxpf s6-arch.tar.xz

rm -rf "$S6_DEST" && mkdir -p "$S6_DEST"

process_service() {
    local SVC=$1
    if [ -d "$S6_SRC/$SVC" ]; then
        cp -r "$S6_SRC/$SVC" "$S6_DEST/$SVC"
        
        # Patch Run Script
        sed -i '1 s|^.*$|#!/bin/bash|' "$S6_DEST/$SVC/run"
        # Injeção de Ambiente com suporte a signal handling
        sed -i '2i source /opt/frigate/venv/bin/activate' "$S6_DEST/$SVC/run"
        sed -i '3i export PYTHONPATH="/opt/frigate/repo"' "$S6_DEST/$SVC/run"
        sed -i '4i export FRIGATE_CONFIG_FILE="/config/config.yaml"' "$S6_DEST/$SVC/run"
        sed -i '5i export PYTHONUNBUFFERED=1' "$S6_DEST/$SVC/run"
        sed -i 's/^s6-svc/# &/' "$S6_DEST/$SVC/run"
        
		if [ "$SVC" == "frigate" ]; then 
			# [THE FIX] Redireciona o 'cd' original para a nossa pasta de código real
			sed -i 's|cd /opt/frigate|cd /opt/frigate/repo|g' "$S6_DEST/$SVC/run"
			sed -i '/exec python3 -u -m frigate/i \
			\
			# Trigger cache clean up to "Error occurred when attempting to maintain recording cache" due to cameras removed from config\
			echo "[Frigate-s6] Cleaning /tmp/cache to avoid errors due to cameras being removed/renamed in config..."\
			/opt/frigate/cleanup_env.sh \
			# Trigger Go2RTC restart to sync config\
			echo "[Frigate-s6] Syncing Go2RTC config..."\
			if [ -d "/opt/frigate/service/go2rtc" ]; then\
				s6-svc -r /opt/frigate/service/go2rtc\
			fi\
			' "$S6_DEST/$SVC/run"
		fi

		if [ "$SVC" == "nginx" ]; then 
			sed -e '/s6-notifyoncheck/ s/^#*/#/' -i "$S6_DEST/$SVC/run"
		fi
        
        rm -f "$S6_DEST/$SVC/finish"
        chmod +x "$S6_DEST/$SVC/run"

        # [V131 Fix] Logger
        if [ -d "$S6_SRC/$SVC-log" ]; then
            mkdir -p "$S6_DEST/$SVC/log"
            echo -e "#!/command/execlineb -P\ns6-log t /dev/shm/logs/$SVC" > "$S6_DEST/$SVC/log/run"
            chmod +x "$S6_DEST/$SVC/log/run"
        fi		
    fi
}

process_service "nginx"
process_service "go2rtc"
process_service "frigate"
process_service "certsync"

# 15. CONFIGURATION
log "Configuring System..."
mkdir -p "$MEDIA_DIR" "$CONFIG_DIR" "$DATABASE_DIR"

#if [ ! -d "/config" ]; then ln -s "$CONFIG_DIR" /config; fi
#if [ ! -d "/media/frigate" ]; then ln -s "$STORAGE_DIR" "$MEDIA_DIR"; fi

if [ "$CONFIG_MODE" -eq 2 ]; then
    log "Generating CLEAN config.yaml..."
    cat <<EOF > "$CONFIG_DIR/config.yaml"
version: $TARGET_VERSION
auth:
  enabled: $AUTH_ENABLED
database:
  path: $DATABASE_DIR/frigate.db
detectors:
  cpu:
    type: cpu
detect:
  enabled: true
mqtt:
  enabled: false
cameras:
  dummy_camera: # <--- this will be changed to your actual camera later
    enabled: False
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:554/rtsp
          roles:
            - detect
EOF
else
    log "Generating DEMO config.yaml..."
    if [ ! -f "/media/frigate/person-bicycle-car-detection.mp4" ]; then
        curl -fsSL "https://github.com/intel-iot-devkit/sample-videos/raw/master/person-bicycle-car-detection.mp4" -o "/media/frigate/person-bicycle-car-detection.mp4"
    fi
    cat <<EOF > "$CONFIG_DIR/config.yaml"
version: $TARGET_VERSION
auth:
  enabled: false
mqtt:
  enabled: false
database:
  path: $DATABASE_DIR/frigate.db
detectors:
  cpu:
    type: cpu
detect:
  enabled: true
objects:
  track:
    - person
    - bicycle
    - car
record:
  enabled: true
  retain:
    days: 0
    mode: motion
snapshots:
  enabled: true
cameras:
  test_cam:
    enabled: true
    ffmpeg:
      inputs:
        - path: /media/frigate/person-bicycle-car-detection.mp4
          input_args: -re -stream_loop -1 -fflags +genpts
          roles:
            - detect
            - record
EOF
fi

# 16. SYSTEMD & PERMISSIONS
log "Creating Systemd Service..."

usermod -a -G render,video root 2>/dev/null || true

cat <<EOF > /opt/frigate/prepare_env.sh
#!/bin/bash
# 1. RAM Cache
mkdir -p /tmp/cache
mountpoint -q /tmp/cache || mount -t tmpfs -o size=1G tmpfs /tmp/cache

mkdir -p /config
rm -f /config/config*
ln -sf "$CONFIG_DIR/config.yaml" /config/config.yaml

# 2. S6 Environment Mock (Fixes 'fatal: unable to envdir')
mkdir -p /run/s6/container_environment
# Populate basic env vars for scripts that might look here
echo "/etc/frigate/config.yaml" > /run/s6/container_environment/FRIGATE_CONFIG_FILE
echo "7.0" > /run/s6/container_environment/DEFAULT_FFMPEG_VERSION
mkdir -p /run/s6-linux-init-container-results && echo "0" > /run/s6-linux-init-container-results/exitcode

# 3. Log Structure
mkdir -p /dev/shm/logs/frigate
mkdir -p /dev/shm/logs/nginx
mkdir -p /dev/shm/logs/go2rtc
chmod -R 777 /dev/shm/logs

# 4. Permissions
chown -R root:root $MEDIA_DIR
chmod -R 777 $MEDIA_DIR

# 5. Nginx IO
[ ! -e /dev/stdin ]  && ln -sf /proc/self/fd/0 /dev/stdin
[ ! -e /dev/stdout ] && ln -sf /proc/self/fd/1 /dev/stdout
[ ! -e /dev/stderr ] && ln -sf /proc/self/fd/2 /dev/stderr
exit 0
EOF
chmod +x /opt/frigate/prepare_env.sh

cat <<EOF > /opt/frigate/cleanup_env.sh
#!/bin/bash
echo "[Cleanup] Wiping transient cache..."
rm -rf /tmp/cache/*
echo "[Cleanup] Environment clean."
exit 0
EOF
chmod +x /opt/frigate/cleanup_env.sh

cat <<EOF > /etc/systemd/system/frigate-s6.service
[Unit]
Description=Frigate NVR (S6-Overlay)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/opt/frigate/prepare_env.sh
ExecStart=/command/s6-svscan $S6_DEST
ExecReload=/command/s6-svc -h $S6_DEST
ExecStopPost=/opt/frigate/cleanup_env.sh
TimeoutStopSec=20s
KillMode=control-group
Restart=always
RestartSec=5

# Env Vars
Environment="TZ=$TIMEZONE"
Environment="FRIGATE_CONFIG_FILE=$CONFIG_DIR/config.yaml"
Environment="LD_LIBRARY_PATH=/usr/local/lib:/usr/lib/frigate"
Environment="DEFAULT_FFMPEG_VERSION=7.0"
Environment="PATH=/command:/usr/local/go2rtc/bin:/usr/local/nginx/sbin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=/root"
Environment="LD_PRELOAD=/usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2"
Environment="PYTHONPATH=/opt/frigate/repo"

[Install]
WantedBy=multi-user.target
EOF

# 17. VERSION GEN
VERSION_FILE="$INSTALL_BASE/repo/frigate/version.py"
CLEAN_VERSION="${TAG#v}"
echo "VERSION = '$CLEAN_VERSION'" > "$VERSION_FILE"
echo "BUILD_VERSION = '$CLEAN_VERSION-baremetal-s6'" >> "$VERSION_FILE"

# 18. ENABLE AND START SERVICES
systemctl daemon-reload
systemctl enable frigate-s6
log "Starting Frigate..."
systemctl start frigate-s6

# 19. INSTALL COMPLETE
echo -e "\n${GREEN}SUCCESS! Frigate S6 Installed.${NC}"
echo "URL: http://<IP>:$HTTP_PORT"
echo "Log file: $LOG_FILE"