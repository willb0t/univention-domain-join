#!/bin/bash
# Test script for Rocky Linux 8 domain join validation
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

echo "=== Rocky Linux 8 Domain Join Validation ==="

# Check if domain joined
if [ ! -f /etc/machine.secret ]; then
    echo "❌ Machine not domain joined (no /etc/machine.secret)"
    exit 1
fi

# Check SSSD status
if ! systemctl is-active --quiet sssd; then
    echo "❌ SSSD service not running"
    exit 1
fi
echo "✅ SSSD service running"

# Check home directory configuration
if grep -q "/nfs/home" /etc/sssd/sssd.conf; then
    echo "✅ Custom home directory (/nfs/home) configured"
else
    echo "❌ Custom home directory not configured"
fi

# Test LDAP connectivity
if ldapsearch -x -b "$(grep ldap_search_base /etc/sssd/sssd.conf | cut -d= -f2 | tr -d ' ')" >/dev/null 2>&1; then
    echo "✅ LDAP connectivity working"
else
    echo "❌ LDAP connectivity failed"
fi

# Check Kerberos configuration
if [ -f /etc/krb5.conf ]; then
    echo "✅ Kerberos configured"
else
    echo "❌ Kerberos not configured"
fi

# Test group enumeration
echo "Testing group enumeration..."
if getent group | grep -q "@"; then
    echo "✅ Domain groups visible"
else
    echo "⚠️  No domain groups found (may be normal if no users logged in yet)"
fi

echo "=== Validation Complete ==="
echo "To test user login: su - <domain_user>"
echo "To test group membership: id <domain_user>"
