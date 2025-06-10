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
  NS=openshift-machine-config-operator
  oc label node \
    -l node-role.kubernetes.io/worker-automount \
    node-role.kubernetes.io/worker-automount- \
    node-role.kubernetes.io/worker='' 
  oc delete mcp worker-automount
  oc delete mc -l machineconfiguration.openshift.io/role=worker-automount
  oc delete machineosconfig worker-automount
  ISTAG=$(oc get imagestream os-image -n $NS -o jsonpath='{.status.tags[].tag}' 2>/dev/null)
  oc delete istag os-image:$ISTAG -n $NS
  # oc create sa pruner -n $NS
  # oc adm policy add-cluster-role-to-user system:image-pruner system:serviceaccount:$NS:resource-pruner
  # oc adm policy add-cluster-role-to-user edit system:serviceaccount:$NS:resource-pruner
  # TOKEN=$(oc create token pruner -n $NS --duration=1h)
  # oc adm --token=$TOKEN prune images
  #oc delete istag os-image:worker-automount-3556fb4b0e35cfd6fa56231ab84708e2 -n $NS
}

cleanup
clear


figlet -w 100 'MachineConfigPool' | lolcat -p 1

p "# MachineConfigPools associate 💻 Nodes with 📦 MachineConfigs"
p "# 🏊 here are the existing machineconfigpools"
pei "oc get mcp"
p

p "# 🎯 this 'worker' machineconfigpool associates MachineConfigs to nodes using labels"
pei "oc get mcp worker -o yaml | yq '.spec.nodeSelector'"
p "# 💻 here are the nodes in the worker pool"
pei "oc get nodes -l node-role.kubernetes.io/worker"
p
p
clear

p "# 🎯 this machineconfigpool references multiple MachineConfigs using labels"
pei "oc get mcp worker -o yaml | yq '.spec.machineConfigSelector'"
p
p "# 📦 here are the machineconfigs in the worker pool"
pei "oc get machineconfigs -l machineconfiguration.openshift.io/role=worker"
p

p "# 🎁 ️these are combined into a 'rendered-worker-*' machineconfig"
p "RENDERED_MC=\$(oc get mcp worker -o jsonpath='{.spec.configuration.name}')"
RENDERED_MC=$(oc get mcp worker -o jsonpath='{.spec.configuration.name}')
p "echo \$RENDERED_MC"
echo $RENDERED_MC
p
clear

p "# 🔥 the rendered machineconfig contains the Ignition which is applied to the nodes"
p "#   this includes the systemd units, configuration files, users, and more eg."
#p "oc describe mc \$RENDERED_MC | bat -r 1:30 -l yaml"
#oc describe mc $RENDERED_MC | bat -r 1:30 -l yaml
pei "oc get mc $RENDERED_MC -o json | jq -r '.spec.config.systemd.units[] | .name' | head"
pei "oc get mc $RENDERED_MC -o json | jq -r '.spec.config.storage.files[] | .path' | head"
p

p "# 📷 the rendered machineconfig also specifies the operating system image"
p "oc get mc \$RENDERED_MC -o yaml | yq '.spec | with_entries(select(.key | contains(\"Image\")))'"
oc get mc $RENDERED_MC -o yaml | yq '.spec | with_entries(select(.key | contains("Image")))'
p
p

clear

figlet -w 100 'Automount MCP' | lolcat -p 1

p "# we need a 'worker-automount' MachineConfigPool for setting up autofs nodes"

p "# 🔍 view the worker-automount MachineConfigPool definition"
pei "bat -H 15 -H 16 -H 19 machineconfigpool.yaml"
p "# 🎯 both 'worker' & 'worker-automount' machineconfigs will be rendered for this pool"
p "#    but only 'worker-automount' nodes will be in the pool"
p
p "# 🔧 create the worker-automount MachineConfigPool"
pei "oc create -f machineconfigpool.yaml"
p
p "# 🔍 no nodes are in the worker-automount pool yet"
pei "oc get nodes -l node-role.kubernetes.io/worker-automount"
p
pei "oc get mcp"
p

clear
figlet -w 100 'MachineOSConfig' | lolcat -p 1

p "# ⚙️ MachineOSConfig defines how to build a custom image with added RPMs"
p "#    and associate it with a pool"
pei "bat -H 6 -H 7 machineosconfig.yaml"
p "# ⬆️jk the image will be pushed to the internal registry"
p
p
clear

p "# 🔧 create the worker-automount MachineOSConfigPool"
pei "oc create -f machineosconfig.yaml"
p
# this will create a deployment/machine-os-builder creates a pod/machine-os-builder-<hash> -l k8s-app=machine-os-builder
# pod/machine-os-builder-<hash> waits to acquire a lease
# pod/machine-os-builder-<hash> creates a MachineOSBuild resource  
# pod/machine-os-builder-<hash> creates a job/build-worker-automount-<hash> (?)
# job/build-worker-automount-<hash>  creates a pod/build-worker-automount-<hash> to perform the build
#
# then a job is created

p "# 🤖 this will trigger a MachineOSBuild of the custom image"
p "# ⏳ wait for the job to be created and build to start"
sleep 10 
pei "oc wait --for=create jobs -n openshift-machine-config-operator -l machineconfiguration.openshift.io/machine-os-config=worker-automount"
JOB=$(oc get jobs -n openshift-machine-config-operator -o jsonpath='{.items[0].metadata.name}')

p "BUILD_POD=\$(oc get pods -l batch.kubernetes.io/job-name=$JOB -o name)"
BUILD_POD=$(oc get pods -l batch.kubernetes.io/job-name=$JOB -o name)
pei "echo $BUILD_POD"
p

p "# ⏳ wait for the MachineOSBuild to complete successfully."
p "# 🪵 watch logs in $BUILD_POD for errors"
pei "oc get machineosbuild -l machineconfiguration.openshift.io/machine-os-config=worker-automount"
pei "oc wait machineosbuild -l machineconfiguration.openshift.io/machine-os-config=worker-automount --for=condition=Succeeded=True --timeout=900s"
p

p "# 📷 machines added to worker-automount pool run this custom image"
pei "oc get mcp worker-automount"
RENDERED_MC=$(oc get mcp worker-automount -o jsonpath='{.spec.configuration.name}')
pei "oc get mc $RENDERED_MC -o yaml | yq '.spec | with_entries(select(.key | contains(\"Image\")))'"
p
