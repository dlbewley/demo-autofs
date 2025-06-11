# Layering Demo Notes

# Demo Setup

```bash
arec () {
	if [[ -z "$CAST_DIR" ]]
	then
		echo "Define \$CAST_DIR as location for recordings"
	else
		echo "Resizing terminal to 50 lines 80 cols"
		printf '\e[8;50;80t'
		CAST=$CAST_DIR/${DEMO:-demo}-${DEMO_STEP}-$(date +%Y%m%d_%H%M).cast
		echo "Remember to 'clear'"
		DEFAULT_USER=$USER ASCIINEMA_REC=1 asciinema rec -e AWS_PROFILE,KUBECONFIG,PROMPT,TEST_WORKER -i 2 -q --overwrite $CAST
		echo "aplay $CAST"
	fi
}
```

```bash
export CAST_DIR=~/src/demos/demo-autofs/casts
export DEMO=layering
```

# Demo Steps

## 00-Cleanup

```bash
export DEMO_STEP=cleanup
arec

export TEST_WORKER=hub-v57jl-worker-0-5z4gs

oc label node $TEST_WORKER \
  node-role.kubernetes.io/worker='' \
  node-role.kubernetes.io/worker-automount-

oc delete mc -l machineconfiguration.openshift.io/role=worker-automount

oc delete machineosconfigs worker-automount
oc delete machineosbuilds --all
oc delete mcp worker-automount
oc delete secret/push-secret -n openshift-machine-config-operator
oc delete secret/pull-and-push-secret -n openshift-machine-config-operator
```

* ../casts/layering-cleanup-20250603_1316.cast

## 01-Secrets

[demo-script-layering-01.sh](demo-script-layering-01.sh)

```bash
export DEMO_STEP=01-secrets
arec
```

This step demonstrates:
* Creating a push secret for the internal registry using a service account token
* Extracting and examining the push secret
* Extracting and examining the global cluster pull secret 
* Combining the push and pull secrets into a new pull-and-push secret
* Creating a secret in openshift-machine-config-operator namespace
* Verifying the secrets exist and match the MachineOSConfig requirements

* ../casts/layering-01-secrets-20250603_1502.cast

[![asciicast](https://asciinema.org/a/721881.svg)](https://asciinema.org/a/721881)

## 02-MachineConfigPool and MachineOSConfig

[demo-script-layering-02.sh](demo-script-layering-02.sh)

```bash
export DEMO_STEP=02-machineosconfig
arec
```

This step demonstrates:
* Explaining MachineConfigPools and how they associate nodes with MachineConfigs
* Examining existing MCPs and their node selectors
* Showing how MCPs reference multiple MachineConfigs via labels
* Exploring the rendered MachineConfig that combines individual configs
* Demonstrating how rendered configs contain systemd units, files, and OS image info
* Creating a new worker-automount MachineConfigPool for autofs nodes
* Explaining how worker-automount will get both worker and worker-automount configs
* Creating a MachineOSConfig to build custom image with added RPMs
* Monitoring the MachineOSBuild process and job completion
* Verifying the custom image is associated with the worker-automount pool

* ../casts/layering-02-machineosconfig-20250609_1929.cast

[![asciicast](https://asciinema.org/a/722700.svg)](https://asciinema.org/a/722700)

## 03-Imaging and Configuration

[demo-script-layering-03.sh](demo-script-layering-03.sh)

```bash
export DEMO_STEP=03-imaging
arec
```

This step demonstrates:
* Checking cluster state with `oc get clusterversion`, `oc get nodes`, and `oc get mcp`
* Selecting a test worker node and setting it as $TEST_WORKER
* Relabeling the node from worker to worker-automount role
* Verifying the worker-automount MCP shows 1 node
* Unpausing the MCP to trigger the node update
* Monitoring the node as it drains and reboots
* Watching Machine Config Daemon logs for update completion
* Verifying successful update via MCP and node status checks
* Confirming autofs RPM is installed on the updated node

* ../casts/demo-03-imaging-20250611_1148.cast

[![asciicast](https://asciinema.org/a/722913.svg)](https://asciinema.org/a/722913)


## 04-Autofs Configuration

[demo-script-layering-04.sh](demo-script-layering-04.sh)

```bash
export DEMO_STEP=04-autofs-config
arec
```

This step demonstrates:
* Regenerating machineconfigs with `make`
* Applying machineconfigs with `oc apply -k`
* Observing the MCP go into an updating state
* Waiting for the node to reboot and MCP to be updated
* Verifying the home directory is an NFS mount

* ../casts/demo-04-autofs-config-20250611_1530.cast

[![asciicast](https://asciinema.org/a/722936.svg)](https://asciinema.org/a/722936)

## 05-Autofs Testing
