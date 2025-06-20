#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025 Univention GmbH
# SPDX-License-Identifier: AGPL-3.0-only

import logging
import os
import time
import subprocess
from typing import Dict

from univention_domain_join.distributions import AbstractJoiner
from univention_domain_join.join_steps.dns_configurator import DnsConfigurator
from univention_domain_join.join_steps.kerberos_configurator import KerberosConfigurator
from univention_domain_join.join_steps.ldap_configurator import LdapConfigurator
from univention_domain_join.join_steps.pam_configurator import PamConfigurator
from univention_domain_join.join_steps.sssd_configurator import SssdConfigurator
from univention_domain_join.utils import ldap
from univention_domain_join.utils.general import execute_as_root, name_is_resolvable, ssh

userinfo_logger = logging.getLogger('userinfo')


class DomainJoinException(Exception):
    pass


class DcResolveException(Exception):
    pass


class Joiner(AbstractJoiner):
    def __init__(self, ucr_variables: Dict[str, str], admin_username: str, admin_pw: str, dc_ip: str, skip_login_manager: bool, force_ucs_dns: bool) -> None:
        self.admin_username = admin_username
        self.admin_pw = admin_pw
        self.dc_ip = dc_ip
        self.skip_login_manager = skip_login_manager
        self.force_ucs_dns = force_ucs_dns
        self.domain = ucr_variables['domainname']
        self.nameservers = [
            ucr_variables['nameserver1'] if ucr_variables['nameserver1'] != "''" else '',
            ucr_variables['nameserver2'] if ucr_variables['nameserver2'] != "''" else '',
            ucr_variables['nameserver3'] if ucr_variables['nameserver3'] != "''" else ''
        ]
        self.ldap_master = ucr_variables['ldap_master']
        self.ldap_base = ucr_variables['ldap_base']
        self.ldap_server_name = ucr_variables['ldap_server_name']
        self.kerberos_realm = ucr_variables['kerberos_realm']
        
        # Ensure required packages are installed
        self._install_required_packages()

    @execute_as_root
    def _install_required_packages(self) -> None:
        """Install packages required for domain join on Rocky Linux."""
        userinfo_logger.info('Installing required packages for Rocky Linux...')
        packages = [
            'sssd', 
            'sssd-ldap', 
            'sssd-tools',
            'openldap-clients', 
            'oddjob', 
            'oddjob-mkhomedir'
        ]
        
        try:
            subprocess.check_call(['dnf', '-y', 'install'] + packages)
        except subprocess.CalledProcessError as e:
            userinfo_logger.critical(f'Failed to install required packages: {e}')
            raise DomainJoinException('Package installation failed')

    def check_if_join_is_possible_without_problems(self) -> None:
        # Rocky Linux doesn't use the same login manager as Ubuntu/Mint
        # so we skip that check
        pass

    def create_backup_of_config_files(self) -> None:
        backup_dir = self.create_backup_dir()
        if self.force_ucs_dns:
            DnsConfigurator(self.nameservers, self.domain).backup(backup_dir)
        
        # Back up LDAP config (path is different on Rocky Linux)
        if os.path.exists('/etc/openldap/ldap.conf'):
            os.makedirs(os.path.join(backup_dir, 'etc/openldap'), exist_ok=True)
            os.system(f'cp /etc/openldap/ldap.conf {backup_dir}/etc/openldap/')
            
        SssdConfigurator().backup(backup_dir)
        PamConfigurator().backup(backup_dir)
        KerberosConfigurator().backup(backup_dir)
        userinfo_logger.info('Created a backup of all configuration files, that will be modified at \'%s\'.' % backup_dir)

    @execute_as_root
    def create_backup_dir(self) -> str:
        backup_dir = os.path.join('/var/univention-backup', time.strftime("%Y%m%d%H%M%S_domain-join", time.gmtime()))
        os.makedirs(backup_dir)
        return backup_dir

    def join_domain(self) -> None:
        try:
            if self.force_ucs_dns:
                userinfo_logger.info('changing network/dns configuration as requested.')
                DnsConfigurator(self.nameservers, self.domain).configure_dns()
                
            # check if we can resolve the ldap_server_name and ldap_master
            if not name_is_resolvable(self.ldap_master):
                raise DcResolveException('The UCS master name %s can not be resolved, please check your DNS settings' % self.ldap_master)
            if not name_is_resolvable(self.ldap_server_name):
                raise DcResolveException('The UCS DC name %s can not be resolved, please check your DNS settings' % self.ldap_server_name)
                
            ldap.authenticate_admin(self.dc_ip, self.admin_username, self.admin_pw)
            admin_dn = LdapConfigurator().get_admin_dn(self.dc_ip, self.admin_username, self.admin_pw, self.ldap_base)
            
            # For Rocky Linux, we want to use LDAP authentication instead of Samba/AD
            # Check if it's a Samba DC - we log this but configure for LDAP regardless
            is_samba_dc = ldap.is_samba_dc(self.admin_username, self.admin_pw, self.dc_ip, admin_dn)
            userinfo_logger.info(f'UCS server is a Samba DC: {is_samba_dc}')
            
            # Configure LDAP - note the path difference for Rocky Linux
            self._configure_ldap(self.dc_ip, self.ldap_server_name, self.admin_username, self.admin_pw, self.ldap_base, admin_dn)
            
            # Configure SSSD for LDAP authentication (not Kerberos)
            self._setup_sssd_ldap(
                self.dc_ip, self.ldap_master, self.ldap_server_name, self.admin_username,
                self.admin_pw, self.ldap_base, self.kerberos_realm, admin_dn
            )
            
            # Configure PAM for Rocky Linux
            self._setup_pam_rocky()
            
            # Configure SELinux to allow LDAP authentication
            self._configure_selinux()
            
            userinfo_logger.info('The domain join was successful.')
            userinfo_logger.info('Please reboot the system.')
        finally:
            ldap.cleanup_authentication(self.dc_ip, self.admin_username, self.admin_pw)
    
    @execute_as_root
    def _configure_ldap(self, dc_ip: str, ldap_server_name: str, admin_username: str, admin_pw: str, ldap_base: str, admin_dn: str) -> None:
        """Configure LDAP for Rocky Linux with proper DNS registration."""
        userinfo_logger.info('Configuring LDAP for Rocky Linux with DNS registration')
        
        # Get the UCS root certificate
        from univention_domain_join.join_steps.root_certificate_provider import RootCertificateProvider
        RootCertificateProvider().provide_ucs_root_certififcate(dc_ip)
        
        # Create machine account and get password with enhanced DNS registration
        ldap_configurator = LdapConfigurator()
        password = ldap_configurator.random_password()
        
        # Get hostname information
        hostname_short = subprocess.check_output(['hostname', '-s']).strip().decode()
        hostname_fqdn = subprocess.check_output(['hostname', '-f']).strip().decode()
        current_ip = subprocess.check_output("hostname -I | awk '{print $1}'", shell=True).strip().decode()
        
        userinfo_logger.info(f'Registering {hostname_short} ({current_ip}) in LDAP and DNS')
        
        # Create or modify machine account with additional attributes
        try:
            # First try the standard approach
            ldap_configurator.modify_old_entry_or_add_machine_to_ldap(
                password, dc_ip, admin_username, admin_pw, ldap_base, admin_dn
            )
            
            # Then update DNS entries via remote commands
            # Get domain zone
            cmd = "udm dns/forward_zone list | grep 'zone:' | head -1 | awk '{print $2}'"
            ssh_process = ssh(admin_username, admin_pw, dc_ip, cmd, stdout=subprocess.PIPE)
            domain_zone = ssh_process.stdout.read().decode().strip()
            
            if domain_zone:
                # Create DNS A record
                userinfo_logger.info(f'Creating DNS forward record for {hostname_short}.{domain_zone}')
                dns_cmd = [
                    'udm', 'dns/host_record', 'create',
                    '--superordinate', f'zoneName={domain_zone},cn=dns,{ldap_base}',
                    '--set', f'name={hostname_short}',
                    '--set', f'ip={current_ip}'
                ]
                ssh(admin_username, admin_pw, dc_ip, dns_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                
                # Create reverse DNS entry if possible
                cmd = "udm dns/reverse_zone list | grep 'subnet:' | head -1 | awk '{print $2}'"
                ssh_process = ssh(admin_username, admin_pw, dc_ip, cmd, stdout=subprocess.PIPE)
                reverse_zone = ssh_process.stdout.read().decode().strip()
                
                if reverse_zone:
                    userinfo_logger.info(f'Creating DNS reverse record for {current_ip}')
                    last_octet = current_ip.split('.')[-1]
                    dns_cmd = [
                        'udm', 'dns/ptr_record', 'create',
                        '--superordinate', f'zoneName={reverse_zone},cn=dns,{ldap_base}',
                        '--set', f'address={last_octet}',
                        '--set', f'ptr_record={hostname_fqdn}.'
                    ]
                    ssh(admin_username, admin_pw, dc_ip, dns_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                else:
                    userinfo_logger.warning('No reverse zone found for creating PTR record')
            else:
                userinfo_logger.warning('Could not determine DNS zone for forward record')
                
            # Verify LDAP entry was created
            verify_cmd = f'ldapsearch -x -LLL -b "{ldap_base}" "(uid={hostname_short})" dn'
            ssh_process = ssh(admin_username, admin_pw, dc_ip, verify_cmd, stdout=subprocess.PIPE)
            if "dn:" in ssh_process.stdout.read().decode():
                userinfo_logger.info('Computer account verified in LDAP')
            else:
                userinfo_logger.warning('Could not verify computer account in LDAP')
                
        except Exception as e:
            userinfo_logger.critical(f'Error during LDAP/DNS registration: {e}')
            raise DomainJoinException(f'LDAP/DNS registration failed: {e}')
        
        # Create LDAP config file (different path on Rocky Linux)
        os.makedirs('/etc/openldap', exist_ok=True)
        ldap_conf = \
            "TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem\n" \
            "URI ldap://%s:7389\n" \
            "BASE %s\n" % (ldap_server_name, ldap_base)
            
        with open('/etc/openldap/ldap.conf', 'w') as conf_file:
            conf_file.write(ldap_conf)
            
        # Create machine secret file
        ldap_configurator.create_machine_secret_file(password)
    
    @execute_as_root
    def _setup_sssd_ldap(self, dc_ip: str, ldap_master: str, ldap_server_name: str, admin_username: str,
                         admin_pw: str, ldap_base: str, kerberos_realm: str, admin_dn: str) -> None:
        """Configure SSSD for LDAP-only authentication with basic group mapping."""
        userinfo_logger.info('Configuring SSSD for LDAP-only authentication with group mapping')
        
        # Get machine DN and password
        machine_dn, _ = ldap.get_machines_udm(dc_ip, admin_username, admin_pw, admin_dn)
        ldap_password = open('/etc/machine.secret').read().strip()
        
        # Create SSSD config with LDAP as both id_provider and auth_provider
        os.makedirs('/etc/sssd', exist_ok=True)
        sssd_conf = \
            '[sssd]\n' \
            'config_file_version = 2\n' \
            'services = nss, pam, sudo\n' \
            'domains = %(kerberos_realm)s\n' \
            '\n' \
            '[nss]\n' \
            'filter_users = root,nobody,halt,sync,shutdown,operator\n' \
            'filter_groups = root\n' \
            'override_homedir = /home/%%u\n' \
            '\n' \
            '[pam]\n' \
            'reconnection_retries = 3\n' \
            '\n' \
            '[domain/%(kerberos_realm)s]\n' \
            'id_provider = ldap\n' \
            'auth_provider = ldap\n' \
            'access_provider = ldap\n' \
            '\n' \
            '# LDAP connection settings\n' \
            'ldap_uri = ldap://%(ldap_server_name)s:7389\n' \
            'ldap_search_base = %(ldap_base)s\n' \
            'ldap_tls_reqcert = never\n' \
            'ldap_tls_cacert = /etc/univention/ssl/ucsCA/CAcert.pem\n' \
            'ldap_default_bind_dn = %(machines_ldap_dn)s\n' \
            'ldap_default_authtok_type = password\n' \
            'ldap_default_authtok = %(ldap_password)s\n' \
            '\n' \
            '# Basic schema settings\n' \
            'ldap_schema = rfc2307bis\n' \
            'ldap_user_name = uid\n' \
            'ldap_user_gecos = displayName\n' \
            'ldap_group_member = uniqueMember\n' \
            'ldap_user_member_of = memberOf\n' \
            '\n' \
            '# Group mapping settings\n' \
            'ldap_group_search_base = %(ldap_base)s\n' \
            'ldap_user_search_base = %(ldap_base)s\n' \
            '\n' \
            '# Simplify and ensure reliability\n' \
            'enumerate = true\n' \
            'cache_credentials = true\n' \
            'use_fully_qualified_names = false\n' \
            % {
                'kerberos_realm': kerberos_realm,
                'ldap_base': ldap_base,
                'ldap_server_name': ldap_server_name,
                'ldap_password': ldap_password,
                'machines_ldap_dn': machine_dn,
            }
            
        with open('/etc/sssd/sssd.conf', 'w') as conf_file:
            conf_file.write(sssd_conf)
            
        os.chmod('/etc/sssd/sssd.conf', 0o600)
        
        # Restart SSSD
        subprocess.check_call(['systemctl', 'restart', 'sssd'])
        subprocess.check_call(['systemctl', 'enable', 'sssd'])
    
    @execute_as_root
    def _setup_pam_rocky(self) -> None:
        """Configure PAM for Rocky Linux."""
        userinfo_logger.info('Configuring PAM for Rocky Linux')
        
        # Use authselect to configure PAM with mkhomedir
        try:
            subprocess.check_call(['authselect', 'select', 'sssd', 'with-mkhomedir', '--force'])
        except subprocess.CalledProcessError as e:
            userinfo_logger.critical(f'Failed to configure PAM: {e}')
            raise DomainJoinException('PAM configuration failed')
    
    @execute_as_root
    def _configure_selinux(self) -> None:
        """Configure SELinux to allow LDAP authentication."""
        userinfo_logger.info('Configuring SELinux for LDAP authentication')
        
        try:
            # Check if SELinux is enabled
            selinux_status = subprocess.check_output(['getenforce']).decode().strip()
            if selinux_status.lower() != 'disabled':
                # Set SELinux boolean to allow LDAP authentication
                subprocess.check_call(['setsebool', '-P', 'authlogin_nsswitch_use_ldap=on'])
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            userinfo_logger.warning(f'SELinux configuration warning: {e}')
