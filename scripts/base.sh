#!/bin/bash

set -e
set -x

# Install pip, and then ironic-python-agent
#
# NOTE: This is not actually needed on host-os images. It is left here,
# however, in case that changes.
install_ironic-agent(){
    # Install pip
    if which wget; then
        wget https://bootstrap.pypa.io/get-pip.py
    elif which curl; then
        curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    fi
    sudo python get-pip.py --quiet #--isolated

    # Install requirements
    sudo pip install --upgrade pip cffi pyOpenSSL setuptools
    sudo pip install -c "https://opendev.org/openstack/requirements/raw/branch/stable/stein/upper-constraints.txt" \
        --no-cache-dir -r "https://raw.githubusercontent.com/openstack/ironic-python-agent/stable/stein/requirements.txt"
    # Now that the requirements have installed, install ironic-python-agent
    sudo pip install -c "https://opendev.org/openstack/requirements/raw/branch/stable/stein/upper-constraints.txt" \
        --no-cache-dir ironic-python-agent
}

# The below is only specific to Fedora 22 as of right now. All other later
# versions do not have issues with facter.
if [[ ! -f /etc/os-release || -f /etc/redhat-release ]];then
    os_name="$(awk '{ print $1 }' /etc/redhat-release | sed 's/"//g')"
    os_version_id="$(awk '{ print $3 }' /etc/redhat-release | sed 's/"//g')"
    if [[ $os_name = "CentOS" ]];then
        if [[ $os_version_id = 5.11 ]];then
            for F in /etc/yum.repos.d/*.repo; do
                sudo bash -c "echo '# EOL DISTRO' > $F"
            done
cat <<_EOF_ | sudo bash -c "cat > /etc/yum.repos.d/Vault.repo"
[base]
name=CentOS-5.11 - Base
baseurl=http://vault.centos.org/5.11/os/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5
enabled=1
[updates]
name=CentOS-5.11 - Updates
baseurl=http://vault.centos.org/5.11/updates/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5
enabled=1
[extras]
name=CentOS-5.11 - Extras
baseurl=http://vault.centos.org/5.11/extras/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5
enabled=1
[centosplus]
name=CentOS-5.11 - Plus
baseurl=http://vault.centos.org/5.11/centosplus/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-5
enabled=1
_EOF_
            sudo yum -y update
            sudo yum -y install epel-release
            sudo yum -y install facter perl rsyslog sudo wget
            sudo yum -y install cloud-init cloud-utils-growpart
        fi
    fi
fi

if [ -f /etc/os-release ]; then
    os_name="$(awk -F= '/^NAME/{ print $2 }' /etc/os-release | sed 's/"//g')"
    os_version_id="$(awk -F= '/^VERSION_ID/{ print $2}' /etc/os-release | sed 's/"//g')"
    if [[ $os_name = "Fedora" ]]; then
        if [[ $os_version_id = 22 ]]; then
            sudo dnf -y install facter ruby rubygems
        elif [[ $os_version_id -le 21 ]]; then
            sudo yum -y update
            sudo yum -y install dnf facter perl redhat-lsb-core rsyslog ruby rubygems wget
        fi
    elif [[ $os_name = *CentOS* ]]; then
        if ! [ -x "$(command -v facter)" ]; then
            echo 'Error: facter is not installed.' >&2
            if [[ $os_version_id = 7 ]]; then
                sudo yum -y install http://download-ib01.fedoraproject.org/pub/epel/7/x86_64/Packages/f/facter-2.4.1-1.el7.x86_64.rpm
            fi
        fi
    fi
fi

codename="$(facter lsbdistcodename)"
os="$(facter operatingsystem)"
os_family="$(facter osfamily)"
os_release="$(facter operatingsystemrelease)"
os_release_major="$(facter operatingsystemrelease | awk -F. '{ print $1 }')"

if [[ $os_family = "Debian" || $os = "Debian" ]]; then
    # We need to cleanup for old repo update issues for hash mismatch
    if [[ $codename = "precise" ]]; then
        sudo apt-get clean
        sudo rm -r /var/lib/apt/lists/*
    fi
    if [[ $os_release_major -gt 6 ]]; then
        sudo apt-get update
        echo "libc6:amd64     libraries/restart-without-asking        boolean true" | sudo debconf-set-selections
        echo "libssl1.1:amd64 libssl1.1/restart-services      string" | sudo debconf-set-selections
        sudo apt-get install -y python-minimal python-dev linux-headers-"$(uname -r)" \
        build-essential zlib1g-dev libssl-dev libreadline-gplv2-dev unzip
    fi
    if [[ $codename != "wheezy" ]] && [[ $codename != "jessie" ]] && [[ $codename != "trusty" ]] && [[ $codename != "precise" ]]; then
        # Uncomment the following line to install ironic-python-agent
        #install_ironic-agent
        sudo apt-get -y install cloud-init cloud-initramfs-growroot
    fi

    # Check for /etc/rc.local and create if needed. This has been depricated in
    # Debian 9 and later. So we need to resolve this in order to regenerate SSH host
    # keys.
    if [ ! -f /etc/rc.local ]; then
        sudo bash -c "echo '#!/bin/sh -e' > /etc/rc.local"
        sudo bash -c "echo 'test -f /etc/ssh/ssh_host_dsa_key || dpkg-reconfigure openssh-server' >> /etc/rc.local"
        sudo bash -c "echo 'exit 0' >> /etc/rc.local"
        sudo chmod +x /etc/rc.local
        sudo systemctl daemon-reload
        sudo systemctl enable rc-local
        sudo systemctl start rc-local
    else
        sudo bash -c "sed -i -e 's|exit 0||' /etc/rc.local"
        sudo bash -c "sed -i -e 's|.*test -f /etc/ssh/ssh_host_dsa_key.*||' /etc/rc.local"
        sudo bash -c "echo 'test -f /etc/ssh/ssh_host_dsa_key || dpkg-reconfigure openssh-server' >> /etc/rc.local"
        sudo bash -c "echo 'exit 0' >> /etc/rc.local"
    fi

    # Fix machine-id issue with duplicate IP addresses being assigned
    if [ -f /etc/machine-id ]; then
        sudo truncate -s 0 /etc/machine-id
    fi

    elif [[ $os_family = "RedHat" ]]; then
    if [[ $os != "Fedora" ]]; then
        sudo yum -y install python-devel
        sudo yum -y groupinstall 'Development Tools'
        sudo yum -y install cloud-init cloud-utils-growpart
        # Uncomment the following line to install ironic-python-agent
        #install_ironic-agent

        elif [[ $os = "Fedora" ]]; then
        if [[ $os_version_id -ge 22 ]]; then
            sudo dnf -y install python-devel python-dnf
            # Uncomment the following line to install ironic-python-agent
            #install_ironic-agent
        else
            sudo dnf -y install python-devel
            # Uncomment the following line to install ironic-python-agent
            #install_ironic-agent
        fi
    fi
    elif [[ $os_family = "Linux" ]]; then
    if [[ $os = "Alpine" ]]; then
        chmod u+s /usr/bin/sudo
        echo -e "http://dl-cdn.alpinelinux.org/alpine/edge/testing\nhttp://dl-cdn.alpinelinux.org/alpine/edge/main" | tee -a /etc/apk/repositories
        apk upgrade --update-cache
        apk add --update-cache python python-dev openssl-dev libffi-dev alpine-sdk linux-headers build-base || true
        # Uncomment the following line to install ironic-python-agent
        #install_ironic-agent
        apk add --update-cache cloud-init
    fi
    elif [[ $os_family = "Archlinux" ]]; then
    yes | sudo pacman -Syyu && yes | sudo pacman -S gc guile autoconf automake \
    binutils bison fakeroot file findutils flex gcc gettext grep \
    groff gzip libtool m4 make pacman patch pkgconf sed sudo systemd \
    texinfo util-linux which python-setuptools python-virtualenv python-pip \
    python-pyopenssl python2-setuptools python2-virtualenv python2-pip \
    python2-pyopenssl
fi
