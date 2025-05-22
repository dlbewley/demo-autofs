> [!WARNING]
> **These MachineConfig resources are generated from Butane `*.bu` files.**
> Do not edit the MachineConfig `*.yaml` files directly.

**Instructions:**

* Make any required changes to the `*.bu` files.
* Make any required changes to the included [scripts](../scripts/).
* Run `make` to generate the new MachineConifg YAMLs.
* `oc apply -k .` them or let ArgoCD take the wheel.