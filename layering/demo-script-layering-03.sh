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

cleanup() {
  echo "Cleaning up..."
  NS=openshift-machine-config-operator
  NODE=$(oc get nodes -l demo=worker-automount -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -n "$NODE" ]; then
    echo -n "Delete node $NODE? (y/n) "
    read -n 1 -s
    echo # Print newline after input
    if [ "$REPLY" = "y" ]; then
      MACHINE=$(oc get node/$NODE -o jsonpath='{.metadata.annotations.machine\.openshift\.io\/machine}' | cut -d/ -f2)
      if [ -n "$MACHINE" ]; then
        oc delete node/$NODE --wait=true
        oc delete machines.machine.openshift.io/$MACHINE -n openshift-machine-api
      else
        echo "Warning: Could not find machine annotation for node $NODE"
        oc delete node/$NODE --wait=true
      fi
      NODE=''
    fi
  fi

  if [ -z "$NODE" ]; then
    echo "Selecting new worker node..."
    NEW_NODE=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra' \
      -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v cnv | sort | tail -1)
    if [ -z "$NEW_NODE" ]; then
      echo "Error: No eligible worker nodes found"
      exit 1
    fi
    export NODE=$NEW_NODE
    oc label node $NODE demo=worker-automount
  fi
  oc patch machineconfigpool/worker-automount --type merge --patch '{"spec":{"paused":true}}'
}

cleanup
clear
# make obvious room in the cast for editing
sleep 1

figlet -w 100 'Node Imaging' | lolcat -p 1


p "# ⚠️ Nodes must be running the custom image"
p "#   BEFORE configuring the added RPMs!"
p "# 🐛https://issues.redhat.com/browse/OCPBUGS-56648"
p

p "# 🔍 View current cluster state"
pei "oc get clusterversion"
pei "oc get nodes -l node-role.kubernetes.io/worker"
pei "oc get mcp"
p

p "# 🎯 Select a test node"
pei "export TEST_WORKER=$NODE"
p

p "# 🏷️  Adjust node-role label & move it to worker-automount pool"
pei "oc label node $TEST_WORKER node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''"
p

p "# 🔍 worker-automount MCP now has a node count of 1"
pei "oc get mcp worker-automount"
p

clear

p "# 🔧 Unpause the MCP to begin update"
pei "oc patch machineconfigpool/worker-automount \
    --type merge --patch '{\"spec\":{\"paused\":false}}'"
p
sleep 5

pei "oc get mcp worker-automount"
p

p "# 🔍 The machine config daemon on the node reacts to the MCP update and triggers a drain"
pei "oc get node/$TEST_WORKER"
p

p "# 🪵 Monitor the MCD logs in another terminal and wait for node to reboot"
# @pmalan is a beast
pei "oc get pods -A -l k8s-app=machine-config-daemon --field-selector=spec.host=$TEST_WORKER -o name"
MCD_POD=$(oc get pods -A -l k8s-app=machine-config-daemon --field-selector=spec.host=$TEST_WORKER -o name)
p
p "oc logs -n openshift-machine-config-operator -f $MCD_POD"
p "... 👀 look for something like this at the end..."
cat <<EOF
I0611 17:26:38.595644    3512 update.go:2786] "Validated on-disk state"
I0611 17:26:38.607920    3512 daemon.go:2340] Completing update to target MachineConfig: rendered-worker-automount-5ffdffe14badbefb26817971e15627a6 / Image: image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:326d0638bb78f372e378988a4bf86c46005ccba0b269503ee05e841ea127945e
I0611 17:26:48.790395    3512 update.go:2786] "Update completed for config rendered-worker-automount-5ffdffe14badbefb26817971e15627a6 and node has been successfully uncordoned"
EOF
p

p "# ⏳ Wait for node to reboot..."
p "entering time warp... 🚀"
PROMPT_TIMEOUT=0
# check status off screen and wait for node to reboot... and hit enter after it's up
p
PROMPT_TIMEOUT=2

p "# 🔍 Reboot complete. Check MCP and node status"
pei "oc get mcp worker-automount"
pei "oc get node $TEST_WORKER"
p

p "# ✅ Verify that the autofs RPM now exists on the node"
pei "oc debug node/$TEST_WORKER -- chroot /host rpm -qi autofs 2>/dev/null"
p
p "# 🎉 now that autofs is installed on the node we can enable and configure automountd"
p
