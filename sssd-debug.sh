#!/bin/bash
# SSSD Debugging and Troubleshooting Script for Rocky Linux UCS Domain Join
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo or switch to the root user."
    exit 1
fi

# Banner
echo "===================================================================="
echo "   SSSD Debugging and Troubleshooting for Univention Domain Join"
echo "   For Rocky Linux 8/9/10"
echo "===================================================================="

# Check SSSD status
echo "Checking SSSD service status..."
systemctl status sssd

# Enable debug mode
echo "Would you like to enable debug mode for SSSD? (y/n)"
read -r enable_debug

if [[ "$enable_debug" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    # Backup the original config
    cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak
    
    # Add debug level
    echo "Setting debug level to 9 (highest)..."
    sed -i '/^\[sssd\]/a debug_level = 9' /etc/sssd/sssd.conf
    sed -i '/^\[nss\]/a debug_level = 9' /etc/sssd/sssd.conf
    sed -i '/^\[pam\]/a debug_level = 9' /etc/sssd/sssd.conf
    sed -i '/^\[domain\//a debug_level = 9' /etc/sssd/sssd.conf
    
    # Restart SSSD
    echo "Restarting SSSD service..."
    systemctl restart sssd
    
    # Display log location
    echo "Debug logs are being written to /var/log/sssd/"
    echo "You can view them with: tail -f /var/log/sssd/*.log"
fi

# Test basic functionality
echo "Testing basic SSSD functionality..."

# Get domain name from SSSD config
domain=$(grep "domains =" /etc/sssd/sssd.conf | awk -F'=' '{print $2}' | tr -d ' ')
echo "Domain: $domain"

# Check if NSS is working
echo "Testing NSS module..."
getent passwd | grep -v "^root" | head -3

# Check if domain users are available
echo "Enter a domain username to test (or press Enter to skip): "
read -r test_user

if [ -n "$test_user" ]; then
    echo "Looking up user $test_user..."
    getent passwd "$test_user"
    
    echo "Checking groups for $test_user..."
    id "$test_user"
    
    echo "Testing user access check..."
    if command -v sssctl &> /dev/null; then
        sssctl user-checks "$test_user" -a
    else
        echo "sssctl not available. Skipping access check."
    fi
fi

# Check LDAP connectivity
echo "Testing LDAP connectivity..."
if [ -f /etc/openldap/ldap.conf ]; then
    ldap_uri=$(grep "^URI" /etc/openldap/ldap.conf | awk '{print $2}')
    ldap_base=$(grep "^BASE" /etc/openldap/ldap.conf | awk '{print $2}')
    
    echo "LDAP URI: $ldap_uri"
    echo "LDAP Base: $ldap_base"
    
    # Test LDAP connection
    echo "Testing LDAP connection..."
    if command -v ldapsearch &> /dev/null; then
        ldapsearch -x -H "$ldap_uri" -b "$ldap_base" -s base 2>&1 | head -10
    else
        echo "ldapsearch not available. Skipping LDAP connection test."
    fi
fi

# Look for common issues in logs
echo "Looking for common errors in SSSD logs..."
grep -i "error\|failed\|denied\|cannot\|invalid" /var/log/sssd/*.log 2>/dev/null | tail -20

# Provide optimization suggestions
echo "Checking for potential performance improvements..."
if grep -q "enumerate = true" /etc/sssd/sssd.conf; then
    echo "NOTICE: 'enumerate = true' is enabled, which may cause performance issues in large directories."
    echo "If you experience slow logins, consider setting 'enumerate = false' and using 'getent passwd username' explicitly."
fi

# Provide common fixes
echo ""
echo "===================================================================="
echo "Common SSSD Issues and Fixes:"
echo ""
echo "1. Authentication failures:"
echo "   - Check if the machine account password is correct in /etc/machine.secret"
echo "   - Verify the machine DN in SSSD config matches the one in LDAP"
echo ""
echo "2. Group mapping issues:"
echo "   - Ensure 'ldap_schema = rfc2307bis' is set"
echo "   - Verify 'ldap_group_member = uniqueMember' matches UCS LDAP schema"
echo ""
echo "3. Home directory creation failures:"
echo "   - Check if authselect profile is properly applied"
echo "   - Run: authselect select sssd with-mkhomedir --force"
echo ""
echo "4. SELinux denials:"
echo "   - Check SELinux status: getenforce"
echo "   - Review denials: ausearch -m avc -ts recent"
echo "   - Set required booleans: setsebool -P authlogin_nsswitch_use_ldap=on"
echo ""
echo "5. To restore default config:"
echo "   - cp /etc/sssd/sssd.conf.bak /etc/sssd/sssd.conf"
echo "   - systemctl restart sssd"
echo "===================================================================="

echo "Troubleshooting complete."
