# vCluster Private Nodes

Private Nodes for vCluster is a feature that allows attaching external, self-managed compute resources—typically virtual machines or bare metal servers—as dedicated nodes for a vCluster control plane. These private nodes run outside the host cluster that vCluster control plane (Kubernetes API server and controller manager) is deployed in, enabling total isolation of workloads from the host’s compute environment and network. This approach allows the use of a different CNI and different CSIs, and is ideal for scenarios requiring stricter security boundaries, custom kernel modules, or specialized hardware (like GPUs), while still benefiting from the ease of using vCluster for the control plane.



