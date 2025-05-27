# Using CoreOS Image Layering to run automountd on OpenShift Nodes

RHEL CoreOS is a container optimized operating system which is distributed via a container image. Typically one does not install software directly into the host operating system, but instead from pulled images running in containers.

The [RHCOS Image Layering](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) feature of OpenShift allows to the ability to install software at the host level in a manner compatible with the automated node lifecycle management performed by OpenShift.

> [!IMPORTANT]
> On cluster image layering is TP as of 4.18 and anticipated to GA in 4.19.
>
> Draft 4.19 docs:
>
> * https://issues.redhat.com/browse/OSDOCS-13346
> * https://87486--ocpdocs-pr.netlify.app/openshift-enterprise/latest/machine_configuration/mco-coreos-layering.html

> [!WARNING]
> Use of image layering will lead to potentially unanticipated reboots when the CA signing cert is rotated and subsequently removed. This occurs at 80% and 100% of the cert lifetime.
> This can be obviated through a coordinated pause of the machineconfig pool.


Note the following limitations when working with the on-cluster layering feature as of 4.18:

* If you scale up a machine set that uses a custom layered image, the nodes reboot two times. The first, when the node is initially created with the base image and a second time when the custom layered image is applied.
* Node disruption policies are not supported on nodes with a custom layered image. As a result the following configuration changes cause a node reboot:
    * Modifying the configuration files in the /var or /etc directory
    * Adding or modifying a systemd service
    * Changing SSH keys
    * Removing mirroring rules from ICSP, ITMS, and IDMS objects
    * Changing the trusted CA, by updating the user-ca-bundle configmap in the openshift-config namespace

## Overview 

To apply a custom layered image to your cluster by using the on-cluster build process, make a MachineOSConfig custom resource (CR) that specifies the following parameters:

* One `MachineOSConfig` resource per machine config pool specifies:
  * the Containerfile to build
  * the machine config pool to associate the build
  * where the final image should be pushed and pulled from
  * the push and pull secrets to use with the image

## Prerequisites

### OpenShift 4.19

* ✅ Testing on OpenShift 4.19rc2 MachineOSConfig v1 was successful. (Until [it wasn't](https://issues.redhat.com/browse/OCPBUGS-56648))
* ❌ Testing on OpenShift 4.18.10 MachineOSConfig v1alpha1 was not successful.

### Provision Image Registry to hold layered image

Identify a registry or [enable the on-cluster registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/setting-up-and-configuring-the-registry#configuring-registry-storage-baremetal)

> [!NOTE]
> Using the on-cluster image registry.
> Adapt if using an external registry.

* Create a PVC on non-default SC for Image Registry storage

```bash
$ cat <<EOF | oc create -f -
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: image-registry-storage-cephfs
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-cephfs
  volumeMode: Filesystem
EOF
```

* Enable the on cluster registry using the above PVC. 

```bash
# Enable registry - if none exists outside cluster
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"managementState":"Managed"}}'

$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"storage":{"pvc":{"claim":"image-registry-storage-cephfs"}}}}'

# account for pvc
$ oc patch configs.imageregistry.operator.openshift.io cluster \
    --type merge --patch '{"spec":{"rolloutStrategy":"Recreate"}}'
```

* Optionally [expose the registry](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/registry/securing-exposing-registry#securing-exposing-registry) for testing pulls off-cluster.

```bash
# Expose registry
$ oc patch configs.imageregistry.operator.openshift.io/cluster \
    --patch '{"spec":{"defaultRoute":true}}' --type=merge
```

### Pull and Push Secrets

Create a pull-secret with the ability to push to the cluster image registry in the `openshift-machine-config-operator` namespace. 

* Create a long duration token (2 year here) per this KCS https://access.redhat.com/solutions/7025261

```bash
export REGISTRY=image-registry.openshift-image-registry.svc:5000
# this user is not in the `-n openshift-machine-config-operator rolebinding/sytem:image-builder`
#export REGISTRY_USER=machine-os-builder
# this user is
export REGISTRY_USER=builder
export REGISTRY_NAMESPACE=openshift-machine-config-operator
export TOKEN=$(oc create token $REGISTRY_USER -n $REGISTRY_NAMESPACE --duration=$((720*24))h)
```

* Use this token to create a secret named `push-secret`.

```bash
oc create secret docker-registry push-secret \
  -n openshift-machine-config-operator \
  --docker-server=$REGISTRY \
  --docker-username=$REGISTRY_USER \
  --docker-password=$TOKEN
```

> [!NOTE]
> Verify the expiration on the token just created:
> `oc extract secret/push-secret -n openshift-machine-config-operator --to=- | jq -r '.auths."image-registry.openshift-image-registry.svc:5000".auth' | base64 -d | cut -d. -f2 | base64 -d`
> 
> {"aud":["https://kubernetes.default.svc"],"exp":1810409199,"iat":1748201199,"iss":"https://kubernetes.default.svc","jti":"f47fdbe6-575b-4187-a678-74839a63ca06","kubernetes.io":{"namespace":"openshift-machine-config-operator","serviceaccount":{"name":"builder","uid":"7f114eb8-da6b-4be1-8bc4-6c9e9119a252"}},"nbf":1748201199,"sub":"system:serviceaccount:openshift-machine-config-operator:builder"}%
>
> `date -r 1810409199`
> Sat May 15 12:26:39 PDT 2027

* Extract the global pull secret to a file

```bash
oc extract secret/pull-secret -n openshift-config --to=- > pull-secret.json

cat pull-secret.json| jq '.auths|keys[]'
"cloud.openshift.com"
"quay.io"
"registry.connect.redhat.com"
"registry.redhat.io"
```

* Extract the created push secret to a file

```bash
oc extract secret/push-secret -n openshift-machine-config-operator --to=- > push-secret.json

cat push-secret.json| jq '.auths|keys[]'
"image-registry.openshift-image-registry.svc:5000"
```

* Combine the global pull secret and the just created push secret into a new pull secret. Refer to this secret in the `MachineOSConfig.spec.baseImagePullSecret` later.

```bash
jq -s '.[0] * .[1]' pull-secret.json push-secret.json > pull-and-push-secret.json

cat pull-and-push-secret.json| jq '.auths|keys[]'
"cloud.openshift.com"
"image-registry.openshift-image-registry.svc:5000"
"quay.io"
"registry.connect.redhat.com"
"registry.redhat.io"

oc create secret generic pull-and-push-secret \
  -n openshift-machine-config-operator \
  --from-file=.dockerconfigjson=pull-and-push-secret.json \
  --type=kubernetes.io/dockerconfigjson
```

* Confirm the pull secret references in  [machineosconfig.yaml](machineosconfig.yaml). 

```bash
oc get secrets -n openshift-machine-config-operator |grep push
pull-and-push-secret                        kubernetes.io/dockerconfigjson        1      64s
push-secret                                 kubernetes.io/dockerconfigjson        1      7m52s

cat machineosconfig.yaml | yq '.spec | with_entries(select(.key | contains("Secret")))'

baseImagePullSecret:
  name: pull-and-push-secret
renderedImagePushSecret:
  name: push-secret
```

## Build Configs and Layered Image

This machineconfig is associated with the just created `worker-automount` machine config pool.

* Create [worker-automount machineconfigpool](machineconfigpool.yaml) to use for initial testing of the image build. Ensure the MCP is initially **paused**.

```bash
oc create -f machineconfigpool.yaml

oc get machineconfigpools
NAME               CONFIG                                             UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1   True      False      False      3              3                   3                     0                      6d
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718   True      False      False      6              6                   6                     0                      6d
worker-automount                                                                                                                                                                      5s
```

> [!IMPORTANT]
> CoreOS uses `/var/home` for user home dirs. We (configure sssd to override)[scripts/homedir.conf] the path returned from LDAP before mounting.

* Ensure that [butane `*.bu` files](machineconfigs/) and the included [scripts](scripts/) are up to date, and regenerate if necessary.

```bash
cd machineconfigs
make
```

* Adjust the role label in the [kustomization.yaml](machineconfigs/kustomization.yaml) if necessary to match the desired machineconfigpool (_worker-automount_).

* Apply all of the [machineconfigs](machineconfigs/kustomization.yaml) using kustomize or just `oc apply` the individual YAMLs.

```bash
oc apply -k machineconfigs
machineconfig.machineconfiguration.openshift.io/99-worker-automount-autofs created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-nfs-homedir-setsebool created
machineconfig.machineconfiguration.openshift.io/99-worker-automount-sssd created
```

> [!NOTE]
> **Entitlements**
>
> Entitlement to download RPMs are enabled by an automatic copy of the `etc-pki-entitlement` secret from the `openshift-config-managed` namespace into the openshift-machine-config-operator namespace.

* Create the MachineOSConfig to define and begin the image build.

```bash
oc create -f machineosconfig.yaml
machineosconfig.machineconfiguration.openshift.io/worker-automount created

# confirm the entitlement secret was copied from openshift-config-managed
oc get secrets -n openshift-machine-config-operator | grep entitle
etc-pki-entitlement-worker-automount        Opaque                                2      2s
```

* A Job in the openshift-machine-config-operator namespace defined by the machineosconfig will create a `MachineOSBuild` and being a build.

```bash
oc get jobs -n openshift-machine-config-operator
NAME                                                      STATUS    COMPLETIONS   DURATION   AGE
build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   Running   0/1           14s        14s

oc get machineosbuild -n openshift-machine-config-operator
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED   AGE
worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   False      True       False       False         False    25s

oc get pods -n openshift-machine-config-operator |grep build
build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1-c65xf   2/2     Running   0               25s
machine-os-builder-57bb5fc9cc-2vx8z                             1/1     Running   0               30s
```

* Pod start up takes a couple of minutes. Watch the logs and confirm a successful push of the resulting image.

Push FAILED
```bash
oc logs  -n  openshift-machine-config-operator -f build-worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1-c65xf
...
Updating Subscription Management repositories.                                                                   subscription-manager is operating in container mode.                                                             Red Hat Enterprise Linux 9 for x86_64 - AppStre  20 MB/s |  60 MB     00:02                                      Red Hat Enterprise Linux 9 for x86_64 - BaseOS   22 MB/s |  58 MB     00:02                                      Last metadata expiration check: 0:00:17 ago on Sun May 25 16:45:50 2025.                                         Dependencies resolved.                                                                                           ================================================================================                                  Package          Arch   Version            Repository                     Size                                  ================================================================================                                 Installing:
 autofs           x86_64 1:5.1.7-60.el9     rhel-9-for-x86_64-baseos-rpms 391 k
 libsss_autofs    x86_64 2.9.6-4.el9_6.2    rhel-9-for-x86_64-baseos-rpms  38 k
 openldap-clients x86_64 2.6.8-4.el9        rhel-9-for-x86_64-baseos-rpms 184 k
...
+ return 0
+ retry buildah push --storage-driver vfs --authfile=/tmp/final-image-push-creds/config.json --digestfile=/tmp/do
ne/digestfile --cert-dir /var/run/secrets/kubernetes.io/serviceaccount image-registry.openshift-image-registry.sv
c:5000/openshift-machine-config-operator/os-image:worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1
+ local count=0
+ buildah push --storage-driver vfs --authfile=/tmp/final-image-push-creds/config.json --digestfile=/tmp/done/dig
estfile --cert-dir /var/run/secrets/kubernetes.io/serviceaccount image-registry.openshift-image-registry.svc:5000
/openshift-machine-config-operator/os-image:worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1
Getting image source signatures
...
Copying config sha256:c50a0e04724ae299990e1750ed70d31bb8091ac1c6c9fb714bbc121fd5312074
Writing manifest to image destination
+ return 0
```

* Check that the MachineOSBuild is successful

```bash
oc get machineosbuild -n openshift-machine-config-operator
NAME                                                PREPARED   BUILDING   SUCCEEDED   INTERRUPTED   FAILED   AGE
worker-automount-5d5651f25efcbf89dd1d2874ad05c8c1   False      False      True        False         False    11m
```

> [!NOTE]
> Creating or modifying MachineConfigs will trigger a new MachineOSBuild.

## Apply Layered Image to Nodes

* View current state

```bash
oc get clusterversion
NAME      VERSION       AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.19.0-rc.2   True        False         6d2h    Cluster version is 4.19.0-rc.2

oc get nodes
NAME                       STATUS   ROLES                  AGE     VERSION
hub-v57jl-cnv-8swxv        Ready    worker                 5d18h   v1.32.4
hub-v57jl-master-0         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-master-1         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-master-2         Ready    control-plane,master   6d3h    v1.32.4
hub-v57jl-store-1-wqqb7    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-store-2-2hhjk    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-store-3-q42r2    Ready    infra,worker           5d23h   v1.32.4
hub-v57jl-worker-0-8thc7   Ready    worker                 3h25m   v1.32.4
hub-v57jl-worker-0-dn4tm   Ready    worker                 5d      v1.32.4

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      6d3h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      6              6                   6                     0                      6d3h
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   True      False      False      0              0                   0                     0                      3h10m
```

* Select a test node to work with.

```bash
export TEST_WORKER=hub-v57jl-worker-0-8thc7
```

* Adjust the `node-role.kubernetes.io` label on the test node so it will be configured by the "worker-auomount" pool which applies the layered image.

```bash
oc label node $TEST_WORKER node-role.kubernetes.io/worker- node-role.kubernetes.io/worker-automount=''

oc get mcp
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
master             rendered-master-7cd94512cb01922e55fd3a8b985320f1             True      False      False      3              3                   3                     0                      6d3h
worker             rendered-worker-72d38a6c7ad0b42b1106ee4cf27b5718             True      False      False      5              5                   5                     0                      6d3h
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   False     False      False      1              0                   0                     0                      3h13m
```

* Notice there is 1 machine in the worker-automount Machine Config Pool. 
* Unpause the MCP to begin updating that machine

```bash
oc patch machineconfigpool/worker-automount \
    --type merge --patch '{"spec":{"paused":false}}'

oc get mcp worker-automount
NAME               CONFIG                                                       UPDATED   UPDATING   DEGRADED   MACHINECOUNT   READYMACHINECOUNT   UPDATEDMACHINECOUNT   DEGRADEDMACHINECOUNT   AGE
worker-automount   rendered-worker-automount-31fcb7e2bf69aaeacc1da796f6d5678e   False     True       False      1              0                   0                     0                      3h15m

oc get nodes $TEST_WORKER
NAME                       STATUS                     ROLES              AGE     VERSION
hub-v57jl-worker-0-8thc7   Ready,SchedulingDisabled   worker-automount   3h32m   v1.32.4
```

* Begin watching the Machine Config Daemon logs for this node in another terminal

```bash
oc get pods -n openshift-machine-config-operator -o wide | grep $TEST_WORKER
kube-rbac-proxy-crio-hub-v57jl-worker-0-8thc7   1/1     Running   2 (3h31m ago)   3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>
machine-config-daemon-bwq89                     2/2     Running   0               3h30m   192.168.4.148   hub-v57jl-worker-0-8thc7   <none>           <none>

oc logs -n openshift-machine-config-operator -f machine-config-daemon-bwq89
...
I0525 20:14:35.568123 3459 update.go:2741] Running: rpm-ostree cleanup -p
Deployments unchanged.
I0525 20:14:35.669725 3459 update.go:2693] Updating OS to layered image "image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5"
I0525 20:14:35.669796 3459 image_manager_helper.go:92] Running captured: rpm-ostree --version
I0525 20:14:35.702277 3459 image_manager_helper.go:194] Linking rpm-ostree authfile to /etc/mco/internal-registry-pull-secret.json
I0525 20:14:35.702360 3459 rpm-ostree.go:183] Executing rebase to image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
I0525 20:14:35.702387 3459 update.go:2741] Running: rpm-ostree rebase --experimental ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
Pulling manifest: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5
Importing: ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5 (digest: sha256:c0c5e5754d0dfc185d28f93c0f365c763bcb647b581c3f6bd3bd37a7f3dc5ba5)
ostree chunk layers already present: 51
custom layers already present: 2
custom layers needed: 2 (18.0?MB)
[0/2] Fetching layer 55fc5bbdeea1d9e6854 (1.4 MB)...done
[1/2] Fetching layer 9cbe6a42d812decb3ef (16.6 MB)...done
Staging deployment...done
Added:
autofs-1:5.1.7-60.el9.x86_64
libsss_autofs-2.9.6-4.el9_6.2.x86_64
openldap-clients-2.6.8-4.el9.x86_64
Changes queued for next boot. Run "systemctl reboot" to start a reboot
...
I0525 20:24:41.871735 3459 update.go:2277] Could not reset unit preset for ipsec.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file ipsec.service does not exist.
)
I0525 20:24:41.871779 3459 file_writers.go:294] Writing systemd unit "kubelet-auto-node-size.service"
I0525 20:24:41.888322 3459 file_writers.go:294] Writing systemd unit "kubelet-dependencies.target"
I0525 20:24:42.834452 3459 update.go:2240] Preset systemd unit "kubelet-dependencies.target"
I0525 20:24:42.834486 3459 file_writers.go:208] Writing systemd unit dropin "01-kubens.conf"
I0525 20:24:42.839658 3459 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0525 20:24:42.839703 3459 file_writers.go:208] Writing systemd unit dropin "10-mco-on-prem-wait-resolv.conf"
I0525 20:24:42.841951 3459 file_writers.go:208] Writing systemd unit dropin "10-mco-default-madv.conf"
I0525 20:24:42.843904 3459 file_writers.go:294] Writing systemd unit "kubelet.service"
I0525 20:24:42.861748 3459 file_writers.go:294] Writing systemd unit "kubens.service"
I0525 20:24:42.877907 3459 file_writers.go:294] Writing systemd unit "machine-config-daemon-firstboot.service"
I0525 20:24:42.893382 3459 file_writers.go:294] Writing systemd unit "machine-config-daemon-pull.service"
I0525 20:24:42.908275 3459 file_writers.go:294] Writing systemd unit "nmstate-configuration.service"
I0525 20:24:42.922699 3459 file_writers.go:294] Writing systemd unit "node-valid-hostname.service"
I0525 20:24:42.939197 3459 file_writers.go:294] Writing systemd unit "nodeip-configuration-vsphere-upi.service"
I0525 20:24:42.957322 3459 file_writers.go:294] Writing systemd unit "nodeip-configuration.service"
I0525 20:24:42.973771 3459 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.path"
I0525 20:24:42.990781 3459 file_writers.go:294] Writing systemd unit "on-prem-resolv-prepender.service"
I0525 20:24:43.006576 3459 file_writers.go:294] Writing systemd unit "ovs-configuration.service"
I0525 20:24:43.025021 3459 file_writers.go:208] Writing systemd unit dropin "10-ovs-vswitchd-restart.conf"
I0525 20:24:44.031059 3459 update.go:2240] Preset systemd unit "ovs-vswitchd.service"
I0525 20:24:44.031093 3459 file_writers.go:208] Writing systemd unit dropin "10-ovsdb-restart.conf"
I0525 20:24:44.032005 3459 file_writers.go:194] Dropin for 10-mco-default-env.conf has no content, skipping write
I0525 20:24:44.886229 3459 update.go:2240] Preset systemd unit "rpm-ostreed.service"
I0525 20:24:44.886283 3459 file_writers.go:294] Writing systemd unit "vsphere-hostname.service"
I0525 20:24:44.920913 3459 file_writers.go:294] Writing systemd unit "wait-for-br-ex-up.service"
I0525 20:24:44.947279 3459 file_writers.go:294] Writing systemd unit "wait-for-ipsec-connect.service"
I0525 20:24:44.974165 3459 file_writers.go:294] Writing systemd unit "wait-for-primary-ip.service"
I0525 20:24:44.995402 3459 file_writers.go:208] Writing systemd unit dropin "mco-disabled.conf"
I0525 20:24:45.019360 3459 update.go:2277] Could not reset unit preset for zincati.service, skipping. (Error msg: error running preset on unit: Failed to preset unit: Unit file zincati.service does not exist.
)
I0525 20:24:45.019428 3459 file_writers.go:294] Writing systemd unit "kubelet-cleanup.service"
I0525 20:24:45.043579 3459 file_writers.go:294] Writing systemd unit "setsebool-nfs-home.service"
I0525 20:24:45.115417 3459 update.go:2873] Already in desired image quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
I0525 20:24:45.115451 3459 update.go:2741] Running: rpm-ostree cleanup -p
Pruned images: 1 (layers: 2)
Freed: 59.0?MB (pkgcache branches: 0)
I0525 20:24:47.976793 3459 update.go:2817] Removing SIGTERM protection
E0525 20:24:47.976850 3459 writer.go:226] Marking Degraded due to: "error enabling units: Failed to enable unit: Unit file autofs.service does not exist.\n"
...
```

> [!WARNING]
> This worked last week, but after re-doing everying as above I'm stuck.
> New issue https://issues.redhat.com/browse/OCPBUGS-56648

```
[root@hub-v57jl-worker-0-8thc7 etc]# rpm-ostree status
State: idle
Deployments:
● ostree-unverified-registry:quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
                   Digest: sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
                  Version: 9.6.20250514-0 (2025-05-14T23:44:17Z)
[root@hub-v57jl-worker-0-8thc7 etc]# rpm -q autofs
package autofs is not installed
[root@hub-v57jl-worker-0-8thc7 etc]# ls sssd
conf.d  pki  sssd.conf
[root@hub-v57jl-worker-0-8thc7 etc]# ls sssd/conf.d
homedir.conf

reboot
# after this br-ex is missing. removed node and started again with hub-v57jl-worker-0-dn4tm
```


### Debug Failed MCP Update 2025-05-26

Machineconfig seems to apply (i.e. /etc/sssd/conf.d/homedir.conf was written) but OS Image does not apply.

* [Full node MCD log](./hub-v57jl-worker-0-dn4tm.mcd.log)

```bash
[root@hub-v57jl-worker-0-dn4tm ~]# rpm-ostree status -v
State: busy
AutomaticUpdates: disabled
Transaction: rebase --experimental 'ostree-unverified-registry:image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e'

  Initiator: client(id:machine-config-operator dbus:1.8151 unit:crio-8ce30d46daaa44c80724020560851c8077761590c768e7fab07a38897a1ac296.scope uid:0)
Deployments:
● ostree-unverified-registry:quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526 (index: 0)
                   Digest: sha256:bb63b13cb9cd0b8c4398f17498f004aff2e7ad770f28c84dc532069ae3a76526
                  Version: 9.6.20250514-0 (2025-05-14T23:44:17Z)
                   Commit: c59fb73267cf3c6c6c44813dd3238888b9c500c8f7bee9521126079f6d455c29
                   Staged: no
                StateRoot: rhcos

# Pulling with /var/lib/kubelet/config.json does not work but /etc/mco/internal-registry-pull-secret.json does
[root@hub-v57jl-worker-0-dn4tm mco]# podman pull --authfile /etc/mco/internal-registry-pull-secret.json image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e
Trying to pull image-registry.openshift-image-registry.svc:5000/openshift-machine-config-operator/os-image@sha256:a18f86073faf0659cfdf8753a2dc0697126515c264b2ce7da2a3b3b6f9931f7e...
Getting image source signatures
Copying blob 8552e7a85c92 skipped: already exists
Copying blob 71721122e569 skipped: already exists
Copying blob 13e28b74b412 skipped: already exists
Copying blob 2616319dd0b6 skipped: already exists
Copying blob f76bdafcae74 skipped: already exists
Copying blob 9ad3fd294b52 skipped: already exists
Copying blob 9b13a23c869f skipped: already exists
Copying blob 57efe3163425 skipped: already exists
Copying blob 1c21b7fdab24 skipped: already exists
Copying blob c77168d99d3c skipped: already exists
Copying blob c0edf73ad374 skipped: already exists
Copying blob d72350910969 skipped: already exists
Copying blob a7d8055279dc skipped: already exists
Copying blob dbe6e35d1324 skipped: already exists
Copying blob 86dd130c82b8 skipped: already exists
Copying blob 43dfcb10b34f skipped: already exists
Copying blob 7b090b813be3 skipped: already exists
Copying blob 00baa96f6230 skipped: already exists
Copying blob 74ad4e117528 skipped: already exists
Copying blob 548bb8e38df2 skipped: already exists
Copying blob 33ed4bd82eee skipped: already exists
Copying blob 9d30772dfd48 skipped: already exists
Copying blob 4696487faff7 skipped: already exists
Copying blob e12bf279c043 skipped: already exists
Copying blob 24abc80a6dbf skipped: already exists
Copying blob f65b36dff745 skipped: already exists
Copying blob f2dd23180414 skipped: already exists
Copying blob f73207ff9240 skipped: already exists
Copying blob 8b62e111a9b7 skipped: already exists
Copying blob cb319d70da5e skipped: already exists
Copying blob 00e24dc97786 skipped: already exists
Copying blob 99b100f4aa2f skipped: already exists
Copying blob cbc00d7179ab skipped: already exists
Copying blob 5479e2bbc9cb skipped: already exists
Copying blob 251b5f43edf7 skipped: already exists
Copying blob bd7b3c980c8f skipped: already exists
Copying blob 91982cedf9c2 skipped: already exists
Copying blob 48844b90a6c9 skipped: already exists
Copying blob 2a34404056f8 skipped: already exists
Copying blob 595813649d13 skipped: already exists
Copying blob f26f793252f5 skipped: already exists
Copying blob 8e8e44669fd1 skipped: already exists
Copying blob c639dcdae0ff skipped: already exists
Copying blob 3202adf0a72b skipped: already exists
Copying blob 176cfcfdcfdb skipped: already exists
Copying blob 082f42ad8236 skipped: already exists
Copying blob c1a31ba9dbc7 skipped: already exists
Copying blob 0c9fb1e1605c skipped: already exists
Copying blob c0f983ada380 skipped: already exists
Copying blob 256c087f65fc skipped: already exists
Copying blob ad312c5c40cc skipped: already exists
Copying blob 3cefea365c61 skipped: already exists
Copying blob 1e8bd20f9c81 skipped: already exists
Copying blob 1f51303d225d done   |
Copying blob 5d877c30355f done   |
Copying config 54c58bb1b7 done   |
Writing manifest to image destination
54c58bb1b721d0dd10ca19b8948972b11c6f5c0c30b627fd16525dcfe65ac314
```

# Testing AutoFS

After above is successful, `$TEST_WORKER` reboots and begins running a custom image with autofs installed and configured.

> [!NOTE]
> These results are from 05-22-25 when everything worked.

Once the node has successfully applied the custom layered image, confirm autofs functionality.

```bash
[root@hub-v57jl-worker-0-99mcp ~]# cat /etc/sssd/conf.d/homedir.conf
override_homedir = /var/home/%u

[root@hub-v57jl-worker-0-99mcp ~]# getent passwd dale
dale:*:1001:1001:Dale:/home/dale:/bin/bash

[root@hub-v57jl-worker-0-99mcp ~]# su - dale
Last login: Thu May 22 13:21:58 UTC 2025 on pts/0

[dale@hub-v57jl-worker-0-99mcp ~]$ id
uid=1001(dale) gid=1001(dale) groups=1001(dale) context=unconfined_u:unconfined_r:unconfined_t:s0-s0:c0.c1023

[dale@hub-v57jl-worker-0-99mcp ~]$ pwd
/home/dale

[dale@hub-v57jl-worker-0-99mcp ~]$ df -h .
Filesystem              Size  Used Avail Use% Mounted on
nfs:/exports/home/dale   29G  1.8G   27G   7% /var/home/dale
```

# Cleanup

```bash
export TEST_WORKER=hub-v57jl-worker-0-99mcp

oc label node $TEST_WORKER \
  node-role.kubernetes.io/worker='' \
  node-role.kubernetes.io/worker-automount-

oc delete machineosconfigs worker-automount
oc delete machineosbuilds --all
oc delete mcp worker-automount
oc delete secret/push-secret -n openshift-machine-config-operator
oc delete secret/pull-and-push-secret -n openshift-machine-config-operator
```

# References

* https://access.redhat.com/solutions/4970731
* https://access.redhat.com/solutions/5598401
* https://redhat-internal.slack.com/archives/C02CZNQHGN8/p1747245572935239
* https://issues.redhat.com//browse/OCPBUGS-53408
* https://access.redhat.com/downloads/content/479/ver=/rhel---9/9.1/x86_64/packages
* [internal deck](https://docs.google.com/presentation/d/14rIn35xjR8cptqzYwDoFO6IOWIUNkSBZG3K2-5WJKok/edit?slide=id.g547716335e_0_220#slide=id.g547716335e_0_220)
* [RHCOS Image Layering 4.18 docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/machine_configuration/mco-coreos-layering) 

<!-- * Opened bug https://issues.redhat.com/browse/OCPBUGS-56279
* Which seems to be this https://issues.redhat.com//browse/OCPBUGS-53408 -->
