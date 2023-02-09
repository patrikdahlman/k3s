#!/bin/sh

set -o errexit
set -o nounset

mkdir -p ~/k3d-with-calico/
cd ~/k3d-with-calico/

# https://docs.tigera.io/calico/3.25/getting-started/kubernetes/k3s/quickstart
test -d calico || {
	mkdir calico
	cd calico
	curl -qfsSLO 'https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/tigera-operator.yaml'
	curl -qfsSLO 'https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/custom-resources.yaml'
	cd ..
}

podman machine init --cpus 4 --memory 8192 --now k3d

# <https://github.com/k3d-io/k3d/issues/1082>
# <https://rootlesscontaine.rs/getting-started/common/cgroup2/#enabling-cpu-cpuset-and-io-delegation>
podman machine ssh k3d sudo /bin/sh -s <<'EOF'
mkdir -p /etc/systemd/system/user@.service.d;
cat >'/etc/systemd/system/user@.service.d/delegate.conf' <<'!'
[Service]
Delegate=cpu cpuset io memory pids
!

systemctl daemon-reload

# Get the user socket path from "podman info".
ln -sf /var/run/user/501/podman/podman.sock /var/run/docker.sock

# This is for Calico pods which mount "/var/lib/kubelet". See <https://docs.tigera.io/calico/3.25/getting-started/kubernetes/k3s/quickstart>.
mkdir -p /var/lib/kubelet
chown core:core /var/lib/kubelet

# NOTE: Alternatively: mount --bind /var/lib/kubelet /var/lib/kubelet && mount --make-rshared /var/lib/kubelet
EOF

# Alternatively, use SSH: "podman system connection ls"
export DOCKER_HOST="unix://${HOME}/.local/share/containers/podman/machine/k3d/podman.sock"

k3d registry create --default-network podman mycluster-registry

# <https://github.com/k3d-io/k3d/issues/1082#issuecomment-1156832664>
# <https://kubernetes.io/docs/tasks/administer-cluster/kubelet-in-userns/>
# <https://docs.k3s.io/advanced#running-k3s-with-rootless-mode-experimental>
k3d cluster create \
	--servers 3 \
	--agents 2 \
	--registry-use mycluster-registry:55568 \
	--volume '/var/lib/kubelet:/var/lib/kubelet:shared@server:*;agent:*' \
	--volume "${PWD}/calico/tigera-operator.yaml:/var/lib/rancher/k3s/server/manifests/calico-tigera-operator.yaml:ro@server:*" \
	--volume "${PWD}/calico/custom-resources.yaml:/var/lib/rancher/k3s/server/manifests/calico-custom-resources.yaml:ro@server:*" \
	--k3s-arg '--kubelet-arg=feature-gates=KubeletInUserNamespace=true@server:*;agent:*' \
	--k3s-arg '--flannel-backend=none@server:*' \
	--k3s-arg '--cluster-cidr=192.168.0.0/16@server:*' \
	--k3s-arg '--disable-network-policy@server:*' \
	--k3s-arg '--disable=traefik@server:*' \
	--k3s-arg '--disable=servicelb@server:*' \
	;

echo 'NOTE: "DOCKER_HOST" must be exported, to make "kubectl" work with this setup:

    export DOCKER_HOST="unix://${HOME}/.local/share/containers/podman/machine/k3d/podman.sock"'
