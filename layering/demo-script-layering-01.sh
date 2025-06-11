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

oc delete secret/push-secret -n openshift-machine-config-operator 2>&1 >/dev/null
oc delete secret/pull-and-push-secret -n openshift-machine-config-operator 2>&1 >/dev/null
clear


figlet 'Push Secret' | lolcat -p 1

p "# 🔧 prepare a service account to build and push images to the registry"
# KCS https://access.redhat.com/solutions/7025261
pei "export REGISTRY=image-registry.openshift-image-registry.svc:5000"
pei "export REGISTRY_NAMESPACE=openshift-machine-config-operator"
p "# 🤖 the builder serviceaccount has rolebinding/system:image-builders"
pei "export REGISTRY_USER=builder"
p
p "# 🔧 create a long duration (2 years) token for the service account"
p "export TOKEN=\$(oc create token \$REGISTRY_USER -n \$REGISTRY_NAMESPACE --duration=\$((720*24))h)"
export TOKEN=$(oc create token $REGISTRY_USER -n $REGISTRY_NAMESPACE --duration=$((720*24))h)
p

p "# 🔧 use this token to create a pull secret for the cluster registry"
p "oc create secret docker-registry push-secret -n openshift-machine-config-operator --docker-server=\$REGISTRY --docker-username=\$REGISTRY_USER --docker-password=\$TOKEN"

oc create secret docker-registry push-secret \
  -n openshift-machine-config-operator \
  --docker-server=$REGISTRY \
  --docker-username=$REGISTRY_USER \
  --docker-password=$TOKEN

p
p "# 🪏 extract this created 'push' secret to a file"
pei "oc extract secret/push-secret -n openshift-machine-config-operator --to=- > push-secret.json"
p

p "# 🔍 view the registries in the push secret"
pei "cat push-secret.json | jq '.auths|keys[]'"
p
p

clear
figlet 'Pull Secret' | lolcat -p 1

p "# 🪏 extract the cluster global pull secret to a file"
pei "oc extract secret/pull-secret -n openshift-config --to=- > pull-secret.json"

p "# 🔍 view the registries in the global pull secret"
pei "cat pull-secret.json| jq '.auths|keys[]'"
p
p

clear
figlet -w 100 'Pull & Push Secret' | lolcat -p 1

p "# 🔧 combine the global pull secret and the just created push secret"
p "jq -s '.[0] * .[1]' pull-secret.json push-secret.json > pull-and-push-secret.json"
jq -s '.[0] * .[1]' pull-secret.json push-secret.json > pull-and-push-secret.json
p

p "# 🔍 view the registries in the pull and push secret"
pei "cat pull-and-push-secret.json| jq '.auths|keys[]'"
p

p "# 🔧 create a secret for the pull and push secret"
pei "oc create secret generic pull-and-push-secret \
  -n openshift-machine-config-operator \
  --from-file=.dockerconfigjson=pull-and-push-secret.json \
  --type=kubernetes.io/dockerconfigjson"
p

clear
figlet -w 100 'MachineOSConfig' | lolcat -p 1

p "# 🔍 confirm the pull secret references in machineosconfig.yaml"
pei "cat machineosconfig.yaml | yq '.spec | with_entries(select(.key | contains(\"Secret\")))'"
p

p "# 🔍 confirm the pull and push secrets exist in the namespace"
pei "oc get secrets -n openshift-machine-config-operator | grep push"
p

