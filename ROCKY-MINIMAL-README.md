# Minimal Univention Domain Join for Rocky Linux 8/9/10

This package provides a simplified, guaranteed-to-work implementation for joining Rocky Linux systems to a Univention Corporate Server (UCS) domain.

## Overview

The minimal implementation focuses on reliability by removing all unnecessary complexity from the SSSD configuration. This results in a basic but functional domain join that provides user authentication and group mapping.

## Components

1. **setup-rocky-minimal.sh**: A streamlined script that performs the minimal necessary steps to join a Rocky Linux system to a UCS domain.

2. **sssd-minimal.sh**: A repair tool to reset SSSD to a known-good configuration if you encounter issues with an existing setup.

3. **sssd-debug.sh**: A diagnostic tool to help troubleshoot issues with SSSD.

## Usage Instructions

### For a New Installation

Run the minimal setup script:

```bash
sudo ./setup-rocky-minimal.sh
```

Follow the prompts to provide:
- UCS domain name (e.g., example.com)
- Domain controller hostname (e.g., dc.example.com)
- Domain administrator username
- Domain administrator password

The script will:
1. Install necessary packages
2. Create the computer account in LDAP
3. Configure a minimal working SSSD setup
4. Configure PAM for home directory creation
5. Set appropriate SELinux settings
6. Test the configuration

### If You Have Issues with an Existing Setup

If you've already tried to join the domain but SSSD fails to start, run:

```bash
sudo ./sssd-minimal.sh
```

This will:
1. Reset SSSD to a minimal working configuration
2. Clear all caches and databases
3. Restart the service with proper permissions

### For Troubleshooting

If you need more detailed diagnostics:

```bash
sudo ./sssd-debug.sh
```

## Minimal SSSD Configuration

The key to this approach is using an absolute minimal SSSD configuration:

```ini
[sssd]
config_file_version = 2
services = nss, pam
domains = REALM

[domain/REALM]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldap://DC_HOST:7389
ldap_search_base = LDAP_BASE
ldap_default_bind_dn = MACHINE_DN
ldap_default_authtok_type = password
ldap_default_authtok = PASSWORD
ldap_schema = rfc2307bis
enumerate = true
```

This configuration:
- Uses only the essential settings
- Avoids syntax problems that can cause SSSD to fail
- Removes all unnecessary options that might conflict
- Focuses on basic LDAP authentication

## Common Issues and Solutions

1. **SSSD fails to start**
   - Check file permissions on `/etc/sssd/sssd.conf` (should be 600)
   - Verify syntax with `sssctl config-check`
   - Clear cache with `rm -rf /var/lib/sss/db/* /var/lib/sss/mc/*`

2. **Cannot connect to LDAP server**
   - Verify hostname resolution with `ping DC_HOST`
   - Check certificate with `openssl s_client -connect DC_HOST:7389`
   - Verify LDAP connection with `ldapsearch -x -h DC_HOST -p 7389 -b "LDAP_BASE" -s base`

3. **Users not found in LDAP**
   - Verify machine account exists in LDAP
   - Check machine password in `/etc/ldap.secret`
   - Verify SSSD service is running with `systemctl status sssd`

## Why This Works

The common issues with SSSD come from:
1. Configuration syntax errors
2. Overly complex configurations with conflicting settings
3. Incorrect permissions
4. Cached data conflicts

This minimal approach addresses all these issues by starting with the simplest possible configuration that is guaranteed to work, then adding functionality incrementally as needed.

## License

AGPL-3.0-only
