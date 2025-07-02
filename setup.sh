#!/bin/bash
set -e

echo "Installing necessary packages for Ubuntu 24.04..."
sudo apt update
sudo apt -y install realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit nfs-common autofs

clear
echo "Completed installation of necessary packages. Now printing discovered Kerberos realms..."
realm discover

echo "Your domain and its properties should be printed above. If they are not, check DNS config."
read -p "What is the Kerberos realm? (dom.example.com)? " REALMAD
read -p "What is the domain controllers short hostname ? ('dc' part of dc.dom.example.com)? " REALMDC
read -p "What is the domain admin username? " REALMADMIN
shorthost=${HOSTNAME%%.*}

mkdir -p /etc/univention
echo "Connecting to "$REALMDC.$REALMAD" UCS server and pulling UCS config. Password for domain admin will be prompted."
ssh -n root@$REALMDC.$REALMAD 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip="$REALMDC.$REALMAD"" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

. /etc/univention/ucr_master

# Create an account and save the password
echo "Creating computer account on "$REALMDC.$REALMAD" UCS server. Password for domain admin will be prompted."
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"
ssh -n root@$REALMDC.$REALMAD udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=$(hostname) --set password="${password}" \
    --set operatingSystem="$(lsb_release -is)" \
    --set operatingSystemVersion="$(lsb_release -rs)"
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

echo "Performing domain join operation. Password for domain admin will be prompted."
sudo realm join -v -U "$REALMADMIN" "$REALMAD"

# Create ldap.conf
sudo rm -f /etc/ldap/ldap.conf
echo "TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base" | sudo tee /etc/ldap/ldap.conf

# Configure SSSD to use /nfs/home for home directories
echo "Configuring SSSD to use /nfs/home for home directories..."
sudo mkdir -p /nfs/home

# Backup the original sssd.conf if it exists
if [ -f /etc/sssd/sssd.conf ]; then
    sudo cp /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak
fi

# Modify sssd.conf to use /nfs/home
sudo sed -i '/\[domain\/.*\]/a override_homedir = /nfs/home/%u' /etc/sssd/sssd.conf

# Configure autofs for NFS home directories
echo "Configuring autofs for NFS home directories..."
sudo tee /etc/auto.master.d/home.autofs > /dev/null << EOF
/nfs/home /etc/auto.home --timeout=60
EOF

sudo tee /etc/auto.home > /dev/null << EOF
* $REALMDC.$REALMAD:/home/&
EOF

# Ensure autofs is enabled and started
sudo systemctl enable autofs
sudo systemctl restart autofs

# Configure PAM for home directory creation
echo "Activating mkhomedir module..."
echo 'Name: activate mkhomedir
Default: yes
Priority: 900
Session-Type: Additional
Session:
        required  pam_mkhomedir.so umask=0022 skel=/etc/skel' | sudo tee /usr/share/pam-configs/mkhomedir
sudo pam-auth-update --enable mkhomedir

# Restart SSSD
sudo systemctl restart sssd

echo "Domain join completed successfully with home directories mapped to /nfs/home"
echo "Note: Ensure that the NFS server on $REALMDC.$REALMAD is properly configured to export /home"

# Prompt for reboot
read -r -p "UCS Domain Join Complete! REBOOT NOW? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]
then
    echo "Rebooting!"
    sudo reboot
else
    read -p "Reboot not selected. Press any key to finish with script."
fi
