#!/usr/bin/env bats

setup_file() {
    REPO_ROOT="$( cd "$(dirname "$BATS_TEST_FILENAME")/.." >/dev/null 2>&1 && pwd )"
    cd $REPO_ROOT
    # install cloud-provider-kind
    make
    TMP_DIR=$(mktemp -d)
    export TMP_DIR
    # install `kind` and `kubectl` to tempdir
    curl -sLo "${TMP_DIR}/kubectl" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x "${TMP_DIR}/kubectl"
    curl -sLo "${TMP_DIR}/kind" https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
    chmod +x "${TMP_DIR}/kind"

    PATH="${TMP_DIR}:${PATH}"
    export PATH
    # create cluster with specific port mappings
    cat << 'EOC' | kind create cluster --name kccm --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    listenAddress: "0.0.0.0"
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    listenAddress: "0.0.0.0"
    protocol: TCP
EOC
    kind get kubeconfig --name kccm > "${TMP_DIR}/kubeconfig"
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready pods --namespace=kube-system -l k8s-app=kube-dns --timeout=3m
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" label node kccm-control-plane node.kubernetes.io/exclude-from-external-load-balancers-
    # run cloud-provider-kind
    nohup bin/cloud-provider-kind  > ${TMP_DIR}/kccm-kind.log 2>&1 &
    CLOUD_PROVIDER_KIND_PID=$(echo $!)
}

teardown_file() {
    kill -9 ${CLOUD_PROVIDER_KIND_PID}
    kind delete cluster --name kccm || true

    if [[ -n "${TMP_DIR:-}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}

test_ExternalTrafficPolicy-3a_Local() { bats_test_begin "ExternalTrafficPolicy: Local"; 
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" apply -f examples/loadbalancer_etp_local.yaml
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready pods -l app=MyLocalApp
    
    POD=$(kubectl --kubeconfig "${TMP_DIR}/kubeconfig" get pod -l app=MyLocalApp -o jsonpath='{.items[0].metadata.name}')
    echo "Pod: $POD"
    
    # Use fixed NodePort 30000 instead of LoadBalancer IP
    for i in {1..10}
    do
        HOSTNAME=$(curl -s http://localhost:30000/hostname || true)
        echo "Attempt $i: Hostname='$HOSTNAME'"
        [[ ! -z "$HOSTNAME" ]] && [[ "$HOSTNAME" = "$POD" ]] && break || sleep 2
    done
    
    echo "Final - Hostname: '$HOSTNAME', Expected: '$POD'"
    [  "$HOSTNAME" = "$POD" ]
}

test_ExternalTrafficPolicy-3a_Cluster() { bats_test_begin "ExternalTrafficPolicy: Cluster"; 
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" apply -f examples/loadbalancer_etp_cluster.yaml
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready pods -l app=MyClusterApp
    
    POD=$(kubectl --kubeconfig "${TMP_DIR}/kubeconfig" get pod -l app=MyClusterApp -o jsonpath='{.items[0].metadata.name}')
    echo "Pod: $POD"
    
    # Use fixed NodePort 30001 instead of LoadBalancer IP
    for i in {1..10}
    do
        HOSTNAME=$(curl -s http://localhost:30001/hostname || true)
        echo "Attempt $i: Hostname='$HOSTNAME'"
        [[ ! -z "$HOSTNAME" ]] && [[ "$HOSTNAME" = "$POD" ]] && break || sleep 2
    done
    
    echo "Final - Hostname: '$HOSTNAME', Expected: '$POD'"
    [  "$HOSTNAME" = "$POD" ]
}
