#!/bin/bash
# Rocky Linux 8 UCS Domain Join Script
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

set -e
HOME_BASE="/nfs/home"

# Check Rocky Linux
[ ! -f /etc/rocky-release ] && { echo "Rocky Linux required"; exit 1; }
[ "$(id -u)" -ne 0 ] && { echo "Run as root"; exit 1; }

# Get config
read -p "UCS domain: " DOMAIN
read -p "DC hostname: " DC
read -p "Admin user: " ADMIN
DC_FQDN="$DC.$DOMAIN"

# Install packages
echo "Installing packages..."
dnf -y install sssd sssd-krb5 sssd-ldap krb5-workstation openldap-clients oddjob oddjob-mkhomedir authselect

# Get UCR variables
echo "Getting UCS config..."
mkdir -p /etc/univention
ssh -o StrictHostKeyChecking=no root@"$DC_FQDN" 'ucr shell' > /etc/univention/ucr_master
source /etc/univention/ucr_master

# Create machine account
echo "Creating machine account..."
PASSWORD=$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)
HOSTNAME=$(hostname -s)
OS_VER=$(grep -oP '[\d\.]+' /etc/rocky-release | head -1)

ssh -o StrictHostKeyChecking=no root@"$DC_FQDN" "udm computers/linux create \
  --position 'cn=computers,$ldap_base' \
  --set name='$HOSTNAME' \
  --set password='$PASSWORD' \
  --set operatingSystem='Rocky Linux' \
  --set operatingSystemVersion='$OS_VER'"

echo "$PASSWORD" > /etc/machine.secret
chmod 400 /etc/machine.secret

# Get CA cert
mkdir -p /etc/univention/ssl/ucsCA
scp -o StrictHostKeyChecking=no root@"$DC_FQDN":/etc/univention/ssl/ucsCA/CAcert.pem /etc/univention/ssl/ucsCA/

# Configure LDAP
mkdir -p /etc/openldap
cat > /etc/openldap/ldap.conf << EOF
TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base
EOF

# Configure SSSD
MACHINE_DN="cn=$HOSTNAME,cn=computers,$ldap_base"
mkdir -p /etc/sssd
cat > /etc/sssd/sssd.conf << EOF
[sssd]
config_file_version = 2
services = nss, pam, sudo
domains = $kerberos_realm

[domain/$kerberos_realm]
auth_provider = krb5
krb5_realm = $kerberos_realm
krb5_server = $ldap_server_name
id_provider = ldap
ldap_uri = ldap://$ldap_server_name:7389
ldap_search_base = $ldap_base
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = $MACHINE_DN
ldap_default_authtok = $PASSWORD
cache_credentials = true
enumerate = true
override_homedir = $HOME_BASE/%u
fallback_homedir = $HOME_BASE/%u
EOF
chmod 600 /etc/sssd/sssd.conf

# Configure Kerberos
cat > /etc/krb5.conf << EOF
[libdefaults]
default_realm = $kerberos_realm
[realms]
$kerberos_realm = {
  kdc = $ldap_server_name
  admin_server = $ldap_server_name
}
[domain_realm]
.$DOMAIN = $kerberos_realm
$DOMAIN = $kerberos_realm
EOF

# Setup home directory and PAM
mkdir -p "$HOME_BASE"
chmod 755 "$HOME_BASE"
authselect select sssd with-mkhomedir --force

# Configure SELinux
command -v setsebool >/dev/null && setsebool -P authlogin_nsswitch_use_ldap=on

# Start services
systemctl enable --now sssd oddjob

echo "Domain join complete! Reboot recommended."
echo "Test with: getent passwd <domain_user>"
