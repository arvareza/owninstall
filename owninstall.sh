#!/bin/bash
# ============================================================
# Instalasi otomatis ownCloud Server 10 di Debian 12
# Stack   : Apache2 + MariaDB + PHP 7.4 (repo sury.org)
# Jaringan: Interface kedua (ens19 -> 192.168.24.220)
# Jalankan: bash owninstall.sh [-d domain] [-u user] [-p pass] [-i iface]
# ============================================================
set -euo pipefail
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export DEBIAN_FRONTEND=noninteractive

# ---------- KONFIGURASI DINAMIS ----------
DEFAULT_DOMAIN="cloud.daffa.com"
DEFAULT_ADMIN_USER="daffa"
# Otomatis ambil interface fisik kedua (ens19)
SECOND_IFACE="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2}' | sed -n '2p')"
TARGET_IFACE="${TARGET_IFACE:-${SECOND_IFACE:-ens19}}"

# 1. Baca dari Environment Variable jika ada
DOMAIN="${DOMAIN:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"

# 2. Baca dari argumen CLI (-d domain -u user -p pass -i interface)
while getopts ":d:u:p:i:h" opt; do
  case "$opt" in
    d) DOMAIN="$OPTARG" ;;
    u) ADMIN_USER="$OPTARG" ;;
    p) ADMIN_PASS="$OPTARG" ;;
    i) TARGET_IFACE="$OPTARG" ;;
    h)
      echo "Penggunaan: bash $0 [-d domain] [-u admin_user] [-p admin_pass] [-i interface]"
      exit 0
      ;;
    \?)
      echo "Opsi tidak valid: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# 3. Tanya secara interaktif jika dijalankan di terminal & nilai belum diisi
if [ -t 0 ]; then
  if [ -z "$DOMAIN" ]; then
    read -r -p "Masukkan Domain ownCloud [${DEFAULT_DOMAIN}]: " DOMAIN
  fi
  if [ -z "$ADMIN_USER" ]; then
    read -r -p "Masukkan Username Admin [${DEFAULT_ADMIN_USER}]: " ADMIN_USER
  fi
  if [ -z "$ADMIN_PASS" ]; then
    while true; do
      read -r -s -p "Masukkan Password Admin (kosongkan untuk generate otomatis): " ADMIN_PASS
      echo
      if [ -z "$ADMIN_PASS" ]; then
        break
      fi
      read -r -s -p "Konfirmasi Password Admin: " ADMIN_PASS_CONFIRM
      echo
      [ "$ADMIN_PASS" = "$ADMIN_PASS_CONFIRM" ] && break
      echo "!! Password tidak cocok, silakan ulangi."
    done
  fi
fi

# 4. Terapkan nilai default / generate otomatis jika masih kosong
DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
ADMIN_USER="${ADMIN_USER:-$DEFAULT_ADMIN_USER}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 16)}"

# Validasi sederhana agar tidak ada spasi pada domain/username
if [[ "$DOMAIN" =~ [[:space:]] ]] || [[ "$ADMIN_USER" =~ [[:space:]] ]]; then
  echo "!! Domain dan Username tidak boleh mengandung spasi." >&2
  exit 1
fi

# ---------- KONFIGURASI SISTEM & DATABASE ----------
DB_NAME="owncloud"
DB_USER="owncloud"
DB_PASS="$(openssl rand -hex 12 2>/dev/null || echo 'DbPass123xyz')"
OC_DIR="/var/www/owncloud"
DATA_DIR="/var/www/owncloud-data"
OC_URL="https://download.owncloud.com/server/stable/owncloud-complete-latest.tar.bz2"
PHP_VER="7.4"      # ownCloud 10 hanya mendukung PHP 7.4
PHP_BIN="/usr/bin/php${PHP_VER}"
# --------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan sebagai root" >&2
  exit 1
fi

occ() { ( cd "$OC_DIR" && sudo -u www-data "$PHP_BIN" occ "$@" ); }

echo "==> [1/10] Update sistem & paket dasar"
apt-get update -y
apt-get install -y openssl apache2 mariadb-server bzip2 unzip curl sudo \
  lsb-release ca-certificates gnupg iproute2

echo "==> [2/10] Menambah repo PHP (sury.org) untuk PHP ${PHP_VER}"
if [ ! -f /etc/apt/sources.list.d/php.list ]; then
  curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb
  dpkg -i /tmp/debsuryorg-archive-keyring.deb
  rm -f /tmp/debsuryorg-archive-keyring.deb
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/php.list
fi
apt-get update -y

echo "==> [3/10] Install PHP ${PHP_VER} + modul"
apt-get install -y \
  libapache2-mod-php${PHP_VER} php${PHP_VER} php${PHP_VER}-cli php${PHP_VER}-common \
  php${PHP_VER}-mysql php${PHP_VER}-gd php${PHP_VER}-curl php${PHP_VER}-mbstring \
  php${PHP_VER}-intl php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-bcmath \
  php${PHP_VER}-gmp php${PHP_VER}-imagick php${PHP_VER}-apcu php${PHP_VER}-bz2 \
  php${PHP_VER}-json php${PHP_VER}-opcache

# Pastikan Apache & CLI memakai PHP 7.4, bukan PHP 8.x bawaan Debian
update-alternatives --set php "$PHP_BIN" || true
systemctl stop apache2 || true

# Matikan semua modul PHP lain dan MPM selain prefork
for m in /etc/apache2/mods-enabled/php*.load; do
  [ -e "$m" ] || continue
  name="$(basename "$m" .load)"
  [ "$name" = "php${PHP_VER}" ] || a2dismod -f "$name" || true
done
a2dismod -f mpm_event mpm_worker >/dev/null 2>&1 || true
a2enmod mpm_prefork "php${PHP_VER}" >/dev/null

# Hilangkan peringatan "Could not reliably determine the server's FQDN"
echo "ServerName ${DOMAIN}" > /etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null

# Hentikan nginx jika aktif agar port 80 bebas untuk Apache
if systemctl is-active --quiet nginx; then
  echo "    Menghentikan & menonaktifkan nginx (port 80 dipakai Apache)"
  systemctl disable --now nginx
fi

# Cek apakah port 80 masih dipakai program lain
OTHER80="$(ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ && $0 !~ /apache2/' || true)"
if [ -n "$OTHER80" ]; then
  echo "!! Port 80 dipakai program lain:" >&2
  echo "$OTHER80" >&2
  exit 1
fi

if ! apache2ctl configtest; then
  echo "!! Konfigurasi Apache error (lihat pesan di atas)." >&2
  exit 1
fi
systemctl enable mariadb apache2
systemctl start mariadb
if ! systemctl restart apache2; then
  echo "!! Apache gagal start. Log terakhir:" >&2
  journalctl -u apache2 --no-pager -n 30 >&2
  exit 1
fi

echo "==> [4/10] Membuat & mengamankan database"
if [ -f "$OC_DIR/config/config.php" ]; then
  EXISTING_DB_PASS=$(sudo -u www-data "$PHP_BIN" -r "include '$OC_DIR/config/config.php'; echo \$CONFIG['dbpassword'] ?? '';" 2>/dev/null || true)
  if [ -n "$EXISTING_DB_PASS" ]; then
    echo "    Instalasi lama terdeteksi, mempertahankan password database yang sudah ada."
    DB_PASS="$EXISTING_DB_PASS"
  fi
fi

mysql -u root <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "==> [5/10] Download, verifikasi & ekstrak ownCloud"
if [ -f "$OC_DIR/version.php" ]; then
  echo "    $OC_DIR sudah lengkap, download dilewati."
else
  rm -rf "$OC_DIR" /tmp/owncloud /tmp/owncloud.tar.bz2*
  cd /tmp
  curl -fL -o owncloud.tar.bz2 "$OC_URL"
  curl -fL -o owncloud.tar.bz2.sha256 "${OC_URL}.sha256"
  awk '{print $1 "  owncloud.tar.bz2"}' owncloud.tar.bz2.sha256 | sha256sum -c -
  tar -xjf owncloud.tar.bz2
  mv /tmp/owncloud "$OC_DIR"
  rm -f /tmp/owncloud.tar.bz2*
fi
mkdir -p "$DATA_DIR"
chown -R www-data:www-data "$OC_DIR" "$DATA_DIR"

echo "==> [6/10] Konfigurasi PHP"
cat > /etc/php/${PHP_VER}/apache2/conf.d/99-owncloud.ini <<EOF
memory_limit = 512M
upload_max_filesize = 2G
post_max_size = 2G
max_execution_time = 360
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 1
apc.enable_cli = 1
EOF
cat > /etc/php/${PHP_VER}/cli/conf.d/99-owncloud.ini <<EOF
memory_limit = 512M
apc.enable_cli = 1
EOF

echo "==> [7/10] Konfigurasi Apache (${DOMAIN})"
cat > /etc/apache2/sites-available/owncloud.conf <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    DocumentRoot ${OC_DIR}

    <Directory ${OC_DIR}>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        SetEnv HOME ${OC_DIR}
        SetEnv HTTP_HOME ${OC_DIR}
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/owncloud_error.log
    CustomLog \${APACHE_LOG_DIR}/owncloud_access.log combined
</VirtualHost>
EOF
a2dissite 000-default.conf >/dev/null 2>&1 || true
a2ensite owncloud.conf
a2enmod rewrite headers env dir mime >/dev/null
grep -qwF "${DOMAIN}" /etc/hosts || echo "127.0.0.1 ${DOMAIN}" >> /etc/hosts
systemctl restart apache2

echo "==> [8/10] Install / sinkronisasi akun admin ownCloud (occ)"
if [ -f "$OC_DIR/config/config.php" ] && grep -q "'installed' => true" "$OC_DIR/config/config.php"; then
  echo "    ownCloud sudah terinstall, menyinkronkan akun admin '${ADMIN_USER}'..."
  if occ user:list | grep -qE "^[[:space:]]*- ${ADMIN_USER}:"; then
    echo "    User '${ADMIN_USER}' sudah ada, memperbarui password..."
    ( cd "$OC_DIR" && OC_PASS="$ADMIN_PASS" sudo -E -u www-data "$PHP_BIN" occ user:resetpassword --password-from-env "$ADMIN_USER" )
  else
    echo "    Membuat user admin baru '${ADMIN_USER}'..."
    ( cd "$OC_DIR" && OC_PASS="$ADMIN_PASS" sudo -E -u www-data "$PHP_BIN" occ user:add --password-from-env --group="admin" "$ADMIN_USER" )
  fi
else
  occ maintenance:install \
    --database "mysql" --database-name "$DB_NAME" \
    --database-user "$DB_USER" --database-pass "$DB_PASS" \
    --data-dir "$DATA_DIR" \
    --admin-user "$ADMIN_USER" --admin-pass "$ADMIN_PASS"
fi

echo "==> [9/10] Trusted domain (interface ${TARGET_IFACE}), cache, cron"
CUR_IP="$(ip -4 -o addr show dev "$TARGET_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
if [ -z "$CUR_IP" ]; then
  echo "!! Interface ${TARGET_IFACE} tidak memiliki alamat IPv4." >&2
  exit 1
fi

occ config:system:set trusted_domains 0 --value=localhost
occ config:system:set trusted_domains 1 --value="$DOMAIN"
occ config:system:set overwrite.cli.url --value="http://${DOMAIN}"
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ background:cron
echo "*/15 * * * * www-data ${PHP_BIN} -f ${OC_DIR}/cron.php" > /etc/cron.d/owncloud

# Jika IP pada interface kedua (ens19) berubah, perbarui index 2 dst. dan hapus sisa index lama
cat > /usr/local/bin/owncloud-update-ip.sh <<EOF
#!/bin/bash
cd ${OC_DIR} || exit 1
IFACE="${TARGET_IFACE}"
i=2
for ip in \$(ip -4 -o addr show dev "\$IFACE" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1); do
  CURRENT=\$(sudo -u www-data ${PHP_BIN} occ config:system:get trusted_domains \$i 2>/dev/null || true)
  if [ "\$CURRENT" != "\$ip" ]; then
    sudo -u www-data ${PHP_BIN} occ config:system:set trusted_domains \$i --value="\$ip"
  fi
  i=\$((i+1))
done

# Hapus index lama yang tersisa (termasuk IP ens18 sebelumnya)
while sudo -u www-data ${PHP_BIN} occ config:system:get trusted_domains \$i >/dev/null 2>&1; do
  sudo -u www-data ${PHP_BIN} occ config:system:delete trusted_domains \$i
  i=\$((i+1))
done
EOF
chmod +x /usr/local/bin/owncloud-update-ip.sh
/usr/local/bin/owncloud-update-ip.sh
cat > /etc/cron.d/owncloud-update-ip <<EOF
@reboot root sleep 30 && /usr/local/bin/owncloud-update-ip.sh
*/5 * * * * root /usr/local/bin/owncloud-update-ip.sh
EOF

echo "==> [10/10] Simpan kredensial & restart"
CRED=/root/owncloud-credentials.txt
cat > "$CRED" <<EOF
URL            : http://${DOMAIN}  (atau http://${CUR_IP})
Interface      : ${TARGET_IFACE}
Admin user     : ${ADMIN_USER}
Admin password : ${ADMIN_PASS}
DB name        : ${DB_NAME}
DB user        : ${DB_USER}
DB password    : ${DB_PASS}
Data dir       : ${DATA_DIR}
PHP            : ${PHP_VER}
EOF
chmod 600 "$CRED"
systemctl restart apache2

echo
echo "=========================================="
echo " ownCloud selesai dipasang!"
echo " Interface  : ${TARGET_IFACE}"
echo " Domain     : http://${DOMAIN}"
echo " IP         : http://${CUR_IP}"
echo " Admin User : ${ADMIN_USER}"
echo " Kredensial lengkap tersimpan di: $CRED"
echo "=========================================="
echo " Di komputer klien, tambahkan ke file hosts:"
echo "   ${CUR_IP} ${DOMAIN}"
echo "=========================================="