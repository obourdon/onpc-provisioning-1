#!/bin/bash

# Exits on errors
set -ex
# Trace everything into specific log file
exec > >(tee -i /var/log/"$(basename "$0" .sh)"_"$(date '+%Y-%m-%d_%H-%M-%S')".log) 2>&1

cat /proc/cmdline > /var/log/onpc_install_cmdline.log

# Store boot arguments in environment
# Need to exclude nameservers and ntp-server due to the potentiality of multiple values
# netcfg/get_nameservers="IP1 IP2 IP3"
# which can lead to parsing errors due to double-quotes
eval $(cat /proc/cmdline | tr ' ' '\n' | grep '=' | egrep -v 'netcfg/get_nameservers=|clock-setup/ntp-server=' | awk -F= '{gsub("/","_",$1);gsub("-","_",$1);printf "%s=%s\n",$1,$2}')

# Update NTP configuration if necessary
if egrep -q 'clock-setup/ntp-server="' /proc/cmdline; then
	ntpservers=$(cat /proc/cmdline | egrep 'clock-setup/ntp-server="' | sed -e 's?.*clock-setup/ntp-server="\([^"]*\)".*?\1?')
	NTPDATE_CONF_FILE=/etc/default/ntpdate
	if [ -f $NTPDATE_CONF_FILE ]; then
		cp $NTPDATE_CONF_FILE "$NTPDATE_CONF_FILE".ORIG
		sed -i -e "s/NTPSERVERS=\".*\"/NTPSERVERS=\"$ntpservers\"/" \
			$NTPDATE_CONF_FILE
	fi
	NTPD_CONF_FILE=/etc/ntp.conf
	if [ -f $NTPD_CONF_FILE ]; then
		cp $NTPD_CONF_FILE "$NTPD_CONF_FILE".ORIG
		# Comment out all server and pool entries and add others
		sed -i -e 's/^server /#server /' -e 's/^pool /#pool /' \
			-e '/ntp server as a fallback/i# Custom ntp server list' \
			$NTPD_CONF_FILE
		for n in $ntpservers; do
			sed -i -e "/# Custom ntp server list/aserver $n" \
				$NTPD_CONF_FILE
		done
	fi
	CHRONY_CONF_FILE=/etc/chrony/chrony.conf
	if [ -f $CHRONY_CONF_FILE ]; then
		cp $CHRONY_CONF_FILE "$CHRONY_CONF_FILE".ORIG
		# Comment out all server and pool entries and add others
		sed -i -e 's/^server /#server /' -e 's/^pool /#pool /' \
			-e '/# Look here for the admin password needed for chronyc/i# Custom ntp server list\n\nmakestep 1 -1\n' \
			$CHRONY_CONF_FILE
		for n in $ntpservers; do
			sed -i -e "/# Custom ntp server list/aserver $n iburst" \
				$CHRONY_CONF_FILE
		done
	fi
fi

# Retrieve proxy information from installation
if [ -f /etc/apt/apt.conf ]; then
	proxy=$(grep Acquire::http::Proxy /etc/apt/apt.conf | sed -e 's/";$//' | awk -F/ '{print $3}')
fi
# If exists, make it default proxy for all processes/envs on this machine
if [ -n "$proxy" ]; then
	echo -e "http_proxy=http://${proxy}/\nftp_proxy=ftp://${proxy}/\nhttps_proxy=https://${proxy}/\nno_proxy=\"localhost,127.0.0.1\"" >>/etc/environment
fi

hostname=$(hostname)
domainname=$(dnsdomainname)
# Put banner in /etc/issue* files
for f in /etc/issue*; do
	sed -i "/^Ubuntu/i $hostname host/machine\n" $f
done
# Add same info in motd and remove some others
if [ -d /etc/update-motd.d ]; then
	echo -e "#!/bin/sh\nprintf \"\\n$hostname host/machine\\n\\n\"" >/etc/update-motd.d/20-machine-name
	chmod 755 /etc/update-motd.d/20-machine-name
	rm -f /etc/update-motd.d/10-help-text
fi

# IPv6 disabling can be done in preseed but is less "generic"
# d-i debian-installer/add-kernel-opts string ipv6.disable=1 ...
# Disable IPv6 if not activated
if [ ! -d /proc/sys/net/ipv6 ]; then
	sed -i -e 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
	update-grub
fi

# Enable extra modules
echo -e 'bonding\n8021q' >>/etc/modules

# Set hostname
echo "${hostname}.${domainname}" >/etc/hostname

# System user sudo priviledges
username=${passwd_username:-vagrant}
echo -e "${username}\tALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/${username}_user

# Populate system user home
# - add and remove some stuff so that 1st console/ssh login messages are cleaned up
# - create new ssh key and potentially add some from internet
su - ${username} -c 'touch .sudo_as_admin_successful && mkdir -p .cache && chmod 700 .cache && touch .cache/motd.legal-displayed && \
 	mkdir -p .ssh && chmod 700 .ssh && ssh-keygen -b 2048 -t rsa -f .ssh/id_rsa -N "" && sed -i -e "s/@ubuntu/@${hostname}.${domainname}/" .ssh/id_rsa.pub && cp .ssh/id_rsa.pub .ssh/authorized_keys && \
	( wget -q -O - https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub >>.ssh/authorized_keys || true ) && \
 	( wget -q -O - http://www.olivierbourdon.com/ssh-keys >>.ssh/authorized_keys || true )'

# Function to install VirtualBox Guest Addditions according to proper version
vbox() {
	echo "Handling VirtualBox platform"
	vboxversion=$(dmidecode | grep vboxVer | awk '{print $NF}' | sed -e 's/.*_//')
	if [ -n "$vboxversion" ]; then
		echo "Found version $vboxversion"
		wget -q -c http://download.virtualbox.org/virtualbox/$vboxversion/VBoxGuestAdditions_${vboxversion}.iso -O /root/VBoxGuestAdditions.iso
		# The software can only be added after 1st boot so that proper kernel is detected and not installation kernel
		cat >/lib/systemd/system/vbox_guest_additions.service <<_EOF
[Unit]
After=sshd.service
Before=systemd-logind.service
Description=Install VirtualBox Guest Additions

[Service]
Type=oneshot
ExecStart=/etc/init.d/vbox_guest_additions
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
_EOF
		chmod 644 /lib/systemd/system/vbox_guest_additions.service
		if ! systemctl enable vbox_guest_additions.service 2>/dev/null; then
			ln -s /lib/systemd/system/vbox_guest_additions.service /etc/systemd/system
		fi
		# The script itself
		cat >/etc/init.d/vbox_guest_additions <<_EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          vbox_guest_additions
# Required-Start:    \$remote_fs \$syslog
# Required-Stop:     \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Configure VirtualBox Guest Additions at 1st boot time
# Description:       Configure VirtualBox Guest Additions at 1st boot time
### END INIT INFO

echo "Running \$0"
mkdir -p /tmp/mnt
if [ -r /root/VBoxGuestAdditions.iso ]; then
	mount -o loop /root/VBoxGuestAdditions.iso /tmp/mnt
	/tmp/mnt/VBoxLinuxAdditions.run
fi
echo "Done running \$0"
if ! systemctl disable vbox_guest_additions.service 2>/dev/null; then
	rm -f /etc/systemd/system/vbox_guest_additions.service
fi
rm -f /root/VBoxGuestAdditions.iso
reboot
_EOF
		chmod 755 /etc/init.d/vbox_guest_additions
	fi
	echo "Done handling VirtualBox platform"
}

# Virtualization specific tasks
if type virt-what >/dev/null 2>&1; then
	virtualization=$(virt-what | tr '\n' ' ' | sed -e 's/  *$//')
fi
if type dmidecode >/dev/null 2>&1; then
	hosttype=$(dmidecode -s system-product-name)
fi
# dmidecode is available and output is used to do some virtualization specific steps
case "$hosttype" in
	VirtualBox)	vbox;;
	*)		echo -e "\nWARNING $(basename $0): unsupported platform $hosttype\n";;
esac

# Regenerate some initrd files if missing
regen=""
for i in /boot/vmlinuz*; do
	kvers=$(basename $i | sed -e 's/^vmlinuz-//')
	if [ ! -f /boot/initrd.img-$kvers ]; then
		update-initramfs -k $kvers -u
		regen=true
	fi
done
# In case some initrd were regenerated, update grub
if [ -n "$regen" ]; then
	update-grub2
fi

# Eject CD-ROM to avoid boot loop
if ! eject; then
	echo "Eject failed (most probably due to USB mounting of ISO)"
fi

exit 0
