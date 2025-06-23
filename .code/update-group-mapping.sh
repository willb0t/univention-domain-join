#!/bin/bash
# Script to update group mapping for Rocky Linux joined to UCS domain
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

# Check if UCR master file exists
if [ ! -f /etc/univention/ucr_master ]; then
    echo "Error: /etc/univention/ucr_master not found. Is this system joined to a UCS domain?"
    exit 1
fi

# Source UCR variables
. /etc/univention/ucr_master

# Extract the domain name from the current config
DOMAIN=$(grep -oP '(?<=domains = )[^\s]+' /etc/sssd/sssd.conf)
if [ -z "$DOMAIN" ]; then
    echo "Error: Could not determine domain name from SSSD configuration."
    exit 1
fi

echo "Detected domain: $DOMAIN"

# Backup the current config
echo "Backing up current SSSD configuration..."
cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%Y%m%d%H%M%S)

# Get machine DN
machine_dn="cn=$(hostname),cn=computers,$ldap_base"
echo "Machine DN: $machine_dn"

# Get machine password
if [ ! -f /etc/ldap.secret ]; then
    echo "Error: /etc/ldap.secret not found. Cannot authenticate to LDAP server."
    exit 1
fi
ldap_password=$(cat /etc/ldap.secret)

# Find the domain section in the config file
DOMAIN_SECTION_START=$(grep -n "^\[domain/$DOMAIN\]" /etc/sssd/sssd.conf | cut -d: -f1)
if [ -z "$DOMAIN_SECTION_START" ]; then
    echo "Error: Could not find domain section in SSSD configuration."
    exit 1
fi

# Extract the necessary values from the current config
LDAP_URI=$(grep -oP '(?<=ldap_uri = )[^\s]+' /etc/sssd/sssd.conf)
LDAP_SEARCH_BASE=$(grep -oP '(?<=ldap_search_base = )[^\s]+' /etc/sssd/sssd.conf)

echo "Updating SSSD configuration with enhanced group mapping..."

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
ldap_default_bind_dn = $machine_dn
ldap_default_authtok_type = password
ldap_default_authtok = $ldap_password
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
ldap_group_search_base = $ldap_base
ldap_group_search_filter = (|(objectClass=posixGroup)(objectClass=univentionGroup)(objectClass=sambaGroupMapping))

# Enhanced group mapping
ldap_group_nesting_level = 5
ldap_initgroups_use_matching_rule_in_chain = True
ldap_user_principal = uid
ldap_group_member_of_user_attr = dn

# Machine account group membership
ldap_use_tokengroups = False

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

# Create a script to query and update group memberships
echo "Creating group membership synchronization script..."
cat > /usr/local/bin/sync-ucs-groups.sh << 'EOF'
#!/bin/bash
# Script to synchronize group memberships from UCS to Rocky Linux
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Source UCR variables
. /etc/univention/ucr_master

# Get the machine DN
machine_dn="cn=$(hostname),cn=computers,$ldap_base"

# Get the machine password
ldap_password=$(cat /etc/ldap.secret)

# Get all groups from UCS
echo "Querying all groups from UCS LDAP directory..."
groups=$(ldapsearch -x -H ldap://$ldap_master:7389 -D "$machine_dn" -w "$ldap_password" \
    -b "$ldap_base" "(objectClass=posixGroup)" dn cn gidNumber uniqueMember)

# Process each group
echo "$groups" | awk '/^dn: / {dn=$0} /^cn: / {cn=$0} /^gidNumber: / {gid=$0} /^$/ {if(dn!="" && cn!="" && gid!="") print dn "\n" cn "\n" gid; dn=""; cn=""; gid=""}' | \
while read -r dn; do
    read -r cn
    read -r gid
    
    # Extract values
    dn_val=${dn#dn: }
    cn_val=${cn#cn: }
    gid_val=${gid#gidNumber: }
    
    echo "Processing group: $cn_val (GID: $gid_val)"
    
    # Check if group exists locally
    if ! getent group "$gid_val" > /dev/null; then
        echo "  Creating local group: $cn_val"
        groupadd -g "$gid_val" "$cn_val"
    fi
done

# Restart SSSD to apply changes
echo "Restarting SSSD service..."
systemctl restart sssd

echo "Group membership synchronization complete."
echo "You can test by running: id username"
echo "Or: getent group groupname"
EOF

chmod +x /usr/local/bin/sync-ucs-groups.sh

# Run the group synchronization script
echo "Running group membership synchronization..."
/usr/local/bin/sync-ucs-groups.sh

# Create a cron job to periodically sync group memberships
echo "Creating cron job for periodic group synchronization..."
cat > /etc/cron.d/sync-ucs-groups << EOF
# Synchronize UCS group memberships every hour
0 * * * * root /usr/local/bin/sync-ucs-groups.sh > /var/log/sync-ucs-groups.log 2>&1
EOF

echo "Restarting SSSD..."
systemctl restart sssd

echo "Group mapping update complete!"
echo "You should now see full group information instead of just GIDs."
echo "You can test by running: id username"
echo "Or: getent group groupname"
