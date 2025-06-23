# Optimized Rocky Linux Domain Join Scripts

This directory contains optimized versions of the scripts for joining Rocky Linux to a Univention Corporate Server (UCS) domain. These scripts have been refactored to be shorter, more efficient, and require fewer login operations to the UCS server.

## Optimized Scripts

1. `setup-rocky-optimized.sh` - Main domain join script
2. `update-group-mapping-optimized.sh` - Script to update group mapping

## Key Optimizations

### SSH Connection Sharing

Both scripts now use SSH connection sharing/multiplexing to reuse a single connection for multiple operations, significantly reducing the number of login prompts:

```bash
SSH_CONTROL="/tmp/ssh_control_socket_$$"
SSH_CMD="ssh -o ControlPath=$SSH_CONTROL"
SSH_OPTS="-o ControlMaster=auto -o ControlPersist=yes"
```

### Server-Side Helper Scripts

Instead of making multiple separate SSH calls for different operations, the scripts now create helper scripts on the UCS server that perform multiple operations in one go:

1. Computer account checking and creation/modification
2. Group membership operations
3. Group information retrieval

### Reduced Network Operations

- Certificate retrieval now uses SSH instead of SCP
- LDAP operations are performed on the UCS server directly
- Group membership operations are batched

## Usage

### Domain Join

To join a Rocky Linux machine to a UCS domain:

```bash
sudo ./setup-rocky-optimized.sh
```

You will be prompted for:
- UCS domain name
- Domain controller's short hostname
- Domain admin username

The script will:
1. Install necessary packages
2. Set up SSH connection sharing
3. Create and execute a helper script on the UCS server
4. Configure SSSD for LDAP authentication
5. Configure PAM for home directory creation
6. Configure SELinux

### Group Mapping Update

To update group mapping for better integration:

```bash
sudo ./update-group-mapping-optimized.sh
```

The script will:
1. Update SSSD configuration with enhanced group mapping
2. Set up SSH connection sharing
3. Create and execute a helper script on the UCS server to get group information
4. Create local groups matching the UCS groups
5. Create a synchronization script and cron job

## Comparison with Original Scripts

### Login Operations

| Script | Original | Optimized |
|--------|----------|-----------|
| setup-rocky.sh | 5+ separate SSH logins | 1 SSH login with connection sharing |
| update-group-mapping.sh | Multiple LDAP connections | 1 SSH login with connection sharing |

### Performance

The optimized scripts are significantly faster, especially on slow network connections, as they:
- Reduce the number of network round-trips
- Combine multiple operations into single requests
- Process data more efficiently

### Maintainability

The optimized scripts are more maintainable as they:
- Use helper functions and variables for better organization
- Include better error handling
- Provide more detailed logging
- Clean up temporary files and connections

## Requirements

- Rocky Linux 8 or later
- SSH client with connection sharing support
- Standard Linux utilities (bash, awk, etc.)
- Root access on the local machine
- Admin access to the UCS server
