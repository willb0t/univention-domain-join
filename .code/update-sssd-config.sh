#!/bin/bash
# Script to update SSSD configuration for proper user mapping on Rocky Linux
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Check if SSSD config exists
if [ ! -f /etc/sssd/sssd.conf ]; then
    echo "Error: /etc/sssd/sssd.conf not found. Is this system joined to a domain?"
    exit 1
fi

# Backup the current config
echo "Backing up current SSSD configuration..."
cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%Y%m%d%H%M%S)

# Extract the domain name from the current config
DOMAIN=$(grep -oP '(?<=domains = )[^\s]+' /etc/sssd/sssd.conf)
if [ -z "$DOMAIN" ]; then
    echo "Error: Could not determine domain name from SSSD configuration."
    exit 1
fi

echo "Detected domain: $DOMAIN"

# Find the domain section in the config file
DOMAIN_SECTION_START=$(grep -n "^\[domain/$DOMAIN\]" /etc/sssd/sssd.conf | cut -d: -f1)
if [ -z "$DOMAIN_SECTION_START" ]; then
    echo "Error: Could not find domain section in SSSD configuration."
    exit 1
fi

# Extract the necessary values from the current config
LDAP_URI=$(grep -oP '(?<=ldap_uri = )[^\s]+' /etc/sssd/sssd.conf)
LDAP_SEARCH_BASE=$(grep -oP '(?<=ldap_search_base = )[^\s]+' /etc/sssd/sssd.conf)
LDAP_DEFAULT_BIND_DN=$(grep -oP '(?<=ldap_default_bind_dn = )[^\s]+' /etc/sssd/sssd.conf)
LDAP_DEFAULT_AUTHTOK=$(grep -oP '(?<=ldap_default_authtok = )[^\s]+' /etc/sssd/sssd.conf)

# Create a temporary file with the updated domain section
TMP_FILE=$(mktemp)
cat > $TMP_FILE << EOF
[domain/$DOMAIN]
id_provider = ldap
auth_provider = ldap
ldap_uri = $LDAP_URI
ldap_search_base = $LDAP_SEARCH_BASE
ldap_tls_reqcert = never
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = $LDAP_DEFAULT_BIND_DN
ldap_default_authtok_type = password
ldap_default_authtok = $LDAP_DEFAULT_AUTHTOK
ldap_schema = rfc2307bis

# User attribute mappings
ldap_user_object_class = posixAccount
ldap_user_name = uid
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_user_home_directory = homeDirectory
ldap_user_shell = loginShell
ldap_user_gecos = displayName
ldap_user_member_of = memberOf
ldap_user_uuid = entryUUID

# Group mappings
ldap_group_object_class = posixGroup
ldap_group_name = cn
ldap_group_gid_number = gidNumber
ldap_group_member = uniqueMember
ldap_group_uuid = entryUUID

# ID mapping
ldap_id_mapping = False
ldap_idmap_autorid_compat = True

# Home directory configuration
fallback_homedir = /home/%u
default_shell = /bin/bash

cache_credentials = true
enumerate = true
EOF

# Find the next section after the domain section
NEXT_SECTION_START=$(tail -n +$((DOMAIN_SECTION_START+1)) /etc/sssd/sssd.conf | grep -n "^\[" | head -1 | cut -d: -f1)
if [ -n "$NEXT_SECTION_START" ]; then
    NEXT_SECTION_START=$((DOMAIN_SECTION_START + NEXT_SECTION_START))
else
    NEXT_SECTION_START=$(wc -l < /etc/sssd/sssd.conf)
    NEXT_SECTION_START=$((NEXT_SECTION_START + 1))
fi

# Create the new config file
NEW_CONFIG=$(mktemp)
head -n $((DOMAIN_SECTION_START-1)) /etc/sssd/sssd.conf > $NEW_CONFIG
cat $TMP_FILE >> $NEW_CONFIG
tail -n +$((NEXT_SECTION_START)) /etc/sssd/sssd.conf >> $NEW_CONFIG

# Replace the old config with the new one
mv $NEW_CONFIG /etc/sssd/sssd.conf
chmod 600 /etc/sssd/sssd.conf

# Clean up
rm -f $TMP_FILE

echo "SSSD configuration updated successfully."
echo "Restarting SSSD service..."
systemctl restart sssd

echo "Update complete. You should now see full user information instead of just UIDs."
echo "You can test by running: id username"
echo "Or: getent passwd username"
