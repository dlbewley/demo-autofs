#!/bin/bash

# git clone https://github.com/paxtonhare/demo-magic.git
source ~/src/demos/demo-magic/demo-magic.sh
TYPE_SPEED=100
PROMPT_TIMEOUT=2
#DEMO_PROMPT="${CYAN}\W${GREEN}➜ ${COLOR_RESET}"
DEMO_PROMPT="${CYAN}\W ${GREEN}$ ${COLOR_RESET}"
DEMO_COMMENT_COLOR=$GREEN
GIT_ROOT=$(git rev-parse --show-toplevel)
DEMO_ROOT=$GIT_ROOT/layering

TEST_WORKER=$(oc get nodes -l demo=worker-automount -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

cleanup() {
  oc delete mc -l machineconfiguration.openshift.io/role=worker-automount
  oc wait mcp/worker-automount --for=condition=Updating=true --timeout=900s
  oc wait machineosbuild -l machineconfiguration.openshift.io/machine-os-config=worker-automount --for=condition=Succeeded=True --timeout=900s
  oc wait mcp/worker-automount --for=condition=Updated=true --timeout=900s
}

cleanup


clear
# make obvious room in the cast for editing
sleep 1

figlet -w 100 'Autofs Config' | lolcat -p 1

p "# 🔧️ Apply MachineConfigs to Configure and Enable Automountd"
p "# ⚠️ Do not apply these MachineConfigs until after the node is running the new image"
p "# 🐛 Bug https://issues.redhat.com/browse/OCPBUGS-56648"
p

p "# Here are the MachineConfigs to apply"
p "# 🔒 configure selinux to allow NFS home directories"
pei "bat -l ini scripts/setsebool-nfs-home.service"
p

p "# 🏠 override the homedir path returned from LDAP to /var/home"
pei "bat -l ini scripts/homedir.conf"
p

p "# 👩🏻 teach sssd to reference LDAP for users and automounts"
pei "bat -l ini scripts/sssd.conf"
p

clear

p "# 🔄 Ensure the machineconfigs are up to date with butane & included configs"
pei "make -C machineconfigs"
p

p "# 🚀 Apply all of the machineconfigs using kustomize"
pei "bat machineconfigs/kustomization.yaml"
p
pei "oc apply -k machineconfigs"
p

sleep 5
clear

p "# 🛠️ the node image will rebuild and the MachineConfigPool will update"
p
p "⏳ Wait for the image build..."
pei "oc wait machineosbuild -l machineconfiguration.openshift.io/machine-os-config=worker-automount --for=condition=Succeeded=True --timeout=900s"
p
p "⏳ Wait for the MCP to begin updating..."
pei "oc wait mcp/worker-automount --for=condition=Updating=true --timeout=900s"
p
p "⏳ Wait for node to reboot...🔄"
pei "oc wait mcp/worker-automount --for=condition=Updated=true --timeout=900s"
p

clear

p "✅ Reboot complete and configs applied"
pei "oc get node $TEST_WORKER"
p

p "🏠 Check that the user's home directory is mounted via autofs"
pei "oc debug node/$TEST_WORKER -- chroot /host getent passwd dale 2>/dev/null"
pei "oc debug node/$TEST_WORKER -- chroot /host df -h /var/home/dale 2>/dev/null"
p

p "🎉 Autofs is configured and working!"
p

p "⚠️ ssh as core doesn't work yet due to squashed home dir, but oc debug as root works"
p
