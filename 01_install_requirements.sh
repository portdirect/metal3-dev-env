#!/usr/bin/env bash
set -ex

source utils/logging.sh

sudo yum install -y libselinux-utils
if selinuxenabled ; then
    sudo setenforce permissive
    sudo sed -i "s/=enforcing/=permissive/g" /etc/selinux/config
fi

# Update to latest packages first
sudo yum -y update

# Install EPEL required by some packages
if [ ! -f /etc/yum.repos.d/epel.repo ] ; then
    if grep -q "Red Hat Enterprise Linux" /etc/redhat-release ; then
        sudo yum -y install http://mirror.centos.org/centos/7/extras/x86_64/Packages/epel-release-7-11.noarch.rpm
    else
        sudo yum -y install epel-release --enablerepo=extras
    fi
fi

# Update to latest packages first
sudo yum -y update

# Install required packages
sudo yum -y install \
  curl \
  dnsmasq \
  NetworkManager \
  bind-utils \
  jq \
  libguestfs-tools \
  libvirt \
  libvirt-devel \
  libvirt-daemon-kvm \
  python-devel \
  python-netaddr \
  python-virtualenv \
  qemu-kvm \
  virt-install \
  gcc \
  podman

GO_TAR_TMP=$(mktemp -d)
curl -o ${GO_TAR_TMP}/go.tar.gz -sSL https://dl.google.com/go/go1.12.2.linux-amd64.tar.gz
GO_BIN_TMP=$(mktemp -d)
tar -xzf ${GO_TAR_TMP}/go.tar.gz -C ${GO_BIN_TMP}
sudo mv ${GO_BIN_TMP}/go /usr/local
echo "export GOROOT=/usr/local/go" >> ${HOME}/.bash_profile
echo "export GOPATH=${HOME}/go" >> ${HOME}/.bash_profile
echo "export PATH=\${GOPATH}/bin:\${GOROOT}/bin:\${PATH}" >> ${HOME}/.bash_profile
source ${HOME}/.bash_profile
mkdir -p ${GOPATH}/bin

if [[ "$(python -c 'import sys; print(sys.version_info[0])')" == "2" ]]; then
    TMP_VIRTUALENV="virtualenv"
else
    TMP_VIRTUALENV="python3 -m virtualenv --python=python3"
fi

# This little dance allows us to install the latest pip and setuptools
# without get_pip.py or the python-pip package (in epel on centos)
if (( $(${TMP_VIRTUALENV} --version | cut -d. -f1) >= 14 )); then
    SETUPTOOLS="--no-setuptools"
fi

# virtualenv 16.4.0 fixed symlink handling. The interaction of the new
# corrected behavior with legacy bugs in packaged virtualenv releases in
# distributions means we need to hold on to the pip bootstrap installation
# chain to preserve symlinks. As distributions upgrade their default
# installations we may not need this workaround in the future
PIPBOOTSTRAP=/var/lib/pipbootstrap

# Create the boostrap environment so we can get pip from virtualenv
sudo ${TMP_VIRTUALENV} --extra-search-dir=/tmp/wheels ${SETUPTOOLS} ${PIPBOOTSTRAP}
source ${PIPBOOTSTRAP}/bin/activate

# Upgrade to the latest version of virtualenv
sudo sh -c "source ${PIPBOOTSTRAP}/bin/activate; pip install --upgrade ${PIP_ARGS} virtualenv"

# Forget the cached locations of python binaries
hash -r

# Create the virtualenv with the updated toolchain for openstack service
sudo mkdir -p /var/lib/openstack
sudo chown $(whoami) /var/lib/openstack
virtualenv /var/lib/openstack

# Deactivate the old bootstrap virtualenv and switch to the new one
deactivate
source /var/lib/openstack/bin/activate

# Install python packages not included as rpms
pip install \
  crudini \
  ansible \
  virtualbmc \
  python-ironicclient \
  python-ironic-inspector-client \
  python-openstackclient
deactivate
echo "export PATH=/var/lib/openstack/bin:\${PATH}" >> ${HOME}/.bash_profile
source ${HOME}/.bash_profile

sudo sh -c "echo PATH=/var/lib/openstack/bin:\$PATH >> /etc/environment"

if ! which minikube 2>/dev/null ; then
    curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 \
          && chmod +x minikube && sudo mv minikube /usr/local/bin/.
fi

if ! which docker-machine-driver-kvm2 >/dev/null ; then
    curl -LO https://storage.googleapis.com/minikube/releases/latest/docker-machine-driver-kvm2 \
          && sudo install docker-machine-driver-kvm2 /usr/local/bin/
fi

if ! which kubectl 2>/dev/null ; then
    curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl \
        && chmod +x kubectl && sudo mv kubectl /usr/local/bin/.
fi

sudo bash -c 'echo "net.ipv4.ip_forward = 1" > /usr/lib/sysctl.d/50-default.conf'
sudo /sbin/sysctl -p

sudo systemctl enable libvirtd.service
sudo systemctl start libvirtd.service
sudo systemctl status libvirtd.service
sudo usermod -a -G libvirt $(whoami)
newgrp libvirt <<EONG
minikube start --vm-driver kvm2
kubectl version
minikube delete
EONG
