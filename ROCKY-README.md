# Univention Domain Join for Rocky Linux 8/9/10

This folder contains scripts and code for joining Rocky Linux 8, 9, and 10 systems to a Univention Corporate Server (UCS) domain. These improvements ensure that all LDAP groups are properly mapped to users.

## Key Components

1. **setup-rocky-improved.sh**: An improved shell script for joining Rocky Linux to a UCS domain
2. **sssd-debug.sh**: A debugging tool to help diagnose and fix SSSD issues
3. Updated Python module for Rocky Linux integration in the main Univention Domain Join tool

## Usage Instructions

### Joining a Rocky Linux System to UCS

1. Make sure you have root access on the Rocky Linux system.

2. Run the setup script:
   ```bash
   sudo ./setup-rocky-improved.sh
   ```

3. Follow the prompts to provide:
   - UCS domain name
   - Domain controller's hostname
   - Domain administrator username
   - Domain administrator password

4. The script will automatically:
   - Install required packages
   - Configure LDAP client
   - Set up SSSD with proper group mapping
   - Configure PAM for home directory creation
   - Set appropriate SELinux settings
   - Update NSS configuration
   - Test the configuration

5. Reboot when prompted to complete the process.

### If You Encounter Issues

If SSSD fails to start or you have problems with authentication or group mapping:

1. Run the debugging script:
   ```bash
   sudo ./sssd-debug.sh
   ```

2. This script will:
   - Check SSSD service status
   - Enable debug logging if requested
   - Test basic SSSD functionality
   - Check LDAP connectivity
   - Look for common errors in logs
   - Provide guidance on common fixes

3. Common issues and solutions:
   - SSSD fails to start: Check logs at `/var/log/sssd/` for specific errors
   - Authentication failures: Verify machine account credentials
   - Group mapping issues: Ensure LDAP schema settings are correct
   - SELinux denials: Set appropriate SELinux booleans

## Configuration Details

### SSSD Configuration

The SSSD configuration has been simplified for reliability while maintaining group mapping support:

```ini
[sssd]
config_file_version = 2
services = nss, pam, sudo
domains = REALM

[nss]
filter_users = root,nobody,halt,sync,shutdown,operator
filter_groups = root
override_homedir = /home/%u

[pam]
reconnection_retries = 3

[domain/REALM]
id_provider = ldap
auth_provider = ldap
access_provider = ldap

# LDAP connection settings
ldap_uri = ldap://LDAP_SERVER:7389
ldap_search_base = LDAP_BASE
ldap_tls_reqcert = never
ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem
ldap_default_bind_dn = MACHINE_DN
ldap_default_authtok_type = password
ldap_default_authtok = PASSWORD

# Basic schema settings
ldap_schema = rfc2307bis
ldap_user_name = uid
ldap_user_gecos = displayName
ldap_group_member = uniqueMember
ldap_user_member_of = memberOf

# Group mapping settings
ldap_group_search_base = LDAP_BASE
ldap_user_search_base = LDAP_BASE

# Simplify and ensure reliability
enumerate = true
cache_credentials = true
use_fully_qualified_names = false
```

## Troubleshooting Tips

1. **Check SSSD logs**:
   ```bash
   tail -f /var/log/sssd/sssd_REALM.log
   ```

2. **Test user lookup**:
   ```bash
   getent passwd username
   ```

3. **Test group membership**:
   ```bash
   id username
   ```

4. **Restart SSSD after config changes**:
   ```bash
   systemctl restart sssd
   ```

5. **Check SELinux status**:
   ```bash
   getenforce
   ausearch -m avc -ts recent
   ```

## Tested Versions

- Rocky Linux 8.x
- Rocky Linux 9.x
- Rocky Linux 10.x (initial support)
- UCS 5.0+

## License

AGPL-3.0-only
